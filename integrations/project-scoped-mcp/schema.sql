-- REVIEW REQUIRED. Additive source only; never auto-applied by the connector.
-- Prerequisites: Supabase Auth roles/auth.uid(), pgvector in public, PostgreSQL 17.
BEGIN;
CREATE SCHEMA ob1_scoped_internal;
REVOKE ALL ON SCHEMA ob1_scoped_internal FROM PUBLIC;
GRANT USAGE ON SCHEMA ob1_scoped_internal TO authenticated;

CREATE TABLE public.ob1_scoped_projects (project_id uuid PRIMARY KEY, project_key text NOT NULL UNIQUE);
CREATE TABLE public.ob1_scoped_members (
 project_id uuid REFERENCES public.ob1_scoped_projects NOT NULL,
 user_id uuid NOT NULL, role text NOT NULL CHECK (role IN ('reader','writer','reviewer')),
 PRIMARY KEY(project_id,user_id)
);
CREATE TABLE public.ob1_scoped_spaces (space_id text PRIMARY KEY, digest text NOT NULL CHECK(digest ~ '^[a-f0-9]{64}$'), dimensions integer NOT NULL CHECK(dimensions=384));
CREATE TABLE public.ob1_scoped_reviews (
 review_id uuid PRIMARY KEY, project_id uuid REFERENCES public.ob1_scoped_projects NOT NULL,
 workstream text NOT NULL, knowledge_id text NOT NULL, source_hash text NOT NULL,
 content_hash text NOT NULL, source_locator text NOT NULL,
 space_id text REFERENCES public.ob1_scoped_spaces NOT NULL, approved_by uuid NOT NULL
);
-- Only the separately approved external service/administrator can attest a vector.
-- Authenticated MCP users have no write grant or receipt-minting RPC.
CREATE TABLE public.ob1_scoped_embeddings (
 receipt_id uuid PRIMARY KEY, project_id uuid REFERENCES public.ob1_scoped_projects NOT NULL,
 workstream text NOT NULL, content_hash text NOT NULL,
 space_id text REFERENCES public.ob1_scoped_spaces NOT NULL, embedding public.vector(384) NOT NULL
);
CREATE TABLE public.ob1_scoped_records (
 record_id uuid PRIMARY KEY DEFAULT gen_random_uuid(), project_id uuid REFERENCES public.ob1_scoped_projects NOT NULL,
 workstream text NOT NULL, knowledge_id text NOT NULL, current_version uuid NOT NULL,
 revision integer NOT NULL CHECK(revision>0),
 UNIQUE(project_id,workstream,knowledge_id), UNIQUE(record_id,project_id,workstream)
);
CREATE TABLE public.ob1_scoped_versions (
 version_id uuid PRIMARY KEY, record_id uuid NOT NULL, project_id uuid NOT NULL, workstream text NOT NULL,
 content text NOT NULL CHECK(length(content) BETWEEN 1 AND 16000), content_hash text NOT NULL,
 source_hash text NOT NULL, source_locator text NOT NULL, review_id uuid REFERENCES public.ob1_scoped_reviews NOT NULL,
 space_id text REFERENCES public.ob1_scoped_spaces NOT NULL, embedding public.vector(384) NOT NULL,
 supersedes uuid, created_at timestamptz NOT NULL DEFAULT now(), created_by uuid NOT NULL,
 UNIQUE(record_id,version_id),
 FOREIGN KEY(record_id,project_id,workstream) REFERENCES public.ob1_scoped_records(record_id,project_id,workstream),
 FOREIGN KEY(record_id,supersedes) REFERENCES public.ob1_scoped_versions(record_id,version_id)
);
ALTER TABLE public.ob1_scoped_records ADD CONSTRAINT ob1_scoped_current_fk
 FOREIGN KEY(record_id,current_version) REFERENCES public.ob1_scoped_versions(record_id,version_id) DEFERRABLE INITIALLY DEFERRED;
CREATE TABLE public.ob1_scoped_events (
 project_id uuid NOT NULL REFERENCES public.ob1_scoped_projects, workstream text NOT NULL,
 event_id text NOT NULL, payload_hash text NOT NULL, version_id uuid REFERENCES public.ob1_scoped_versions NOT NULL,
 PRIMARY KEY(project_id,workstream,event_id)
);

ALTER TABLE public.ob1_scoped_projects ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.ob1_scoped_members ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.ob1_scoped_spaces ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.ob1_scoped_reviews ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.ob1_scoped_embeddings ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.ob1_scoped_records ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.ob1_scoped_versions ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.ob1_scoped_events ENABLE ROW LEVEL SECURITY;
CREATE POLICY member_self ON public.ob1_scoped_members FOR SELECT TO authenticated USING(user_id=(SELECT auth.uid()));
CREATE POLICY space_read ON public.ob1_scoped_spaces FOR SELECT TO authenticated USING((SELECT auth.uid()) IS NOT NULL);
CREATE POLICY project_read ON public.ob1_scoped_projects FOR SELECT TO authenticated USING(EXISTS(SELECT 1 FROM public.ob1_scoped_members m WHERE m.project_id=ob1_scoped_projects.project_id AND m.user_id=(SELECT auth.uid())));
CREATE POLICY review_read ON public.ob1_scoped_reviews FOR SELECT TO authenticated USING(EXISTS(SELECT 1 FROM public.ob1_scoped_members m WHERE m.project_id=ob1_scoped_reviews.project_id AND m.user_id=(SELECT auth.uid())));
CREATE POLICY record_read ON public.ob1_scoped_records FOR SELECT TO authenticated USING(EXISTS(SELECT 1 FROM public.ob1_scoped_members m WHERE m.project_id=ob1_scoped_records.project_id AND m.user_id=(SELECT auth.uid())));
CREATE POLICY version_read ON public.ob1_scoped_versions FOR SELECT TO authenticated USING(EXISTS(SELECT 1 FROM public.ob1_scoped_members m WHERE m.project_id=ob1_scoped_versions.project_id AND m.user_id=(SELECT auth.uid())));
CREATE POLICY event_read ON public.ob1_scoped_events FOR SELECT TO authenticated USING(EXISTS(SELECT 1 FROM public.ob1_scoped_members m WHERE m.project_id=ob1_scoped_events.project_id AND m.user_id=(SELECT auth.uid())));
REVOKE ALL ON public.ob1_scoped_projects, public.ob1_scoped_members, public.ob1_scoped_spaces, public.ob1_scoped_reviews, public.ob1_scoped_records, public.ob1_scoped_versions, public.ob1_scoped_events FROM PUBLIC, anon, authenticated;
REVOKE ALL ON public.ob1_scoped_embeddings FROM PUBLIC,anon,authenticated;
GRANT SELECT ON public.ob1_scoped_projects, public.ob1_scoped_members, public.ob1_scoped_spaces, public.ob1_scoped_reviews, public.ob1_scoped_records, public.ob1_scoped_versions, public.ob1_scoped_events TO authenticated;

CREATE FUNCTION ob1_scoped_internal.authorise(p jsonb, writing boolean DEFAULT false) RETURNS void
LANGUAGE plpgsql SECURITY INVOKER SET search_path='' AS $$
BEGIN
 IF auth.uid() IS NULL OR coalesce(p->>'projectId','')='' OR coalesce(p->>'workstream','')='' OR
 NOT EXISTS(SELECT 1 FROM public.ob1_scoped_members m WHERE m.project_id=(p->>'projectId')::uuid AND m.user_id=auth.uid() AND (NOT writing OR m.role='writer')) THEN
  RAISE insufficient_privilege USING MESSAGE='PROJECT_FORBIDDEN';
 END IF;
END $$;

CREATE FUNCTION ob1_scoped_internal.render(v public.ob1_scoped_versions) RETURNS jsonb
LANGUAGE sql SECURITY INVOKER SET search_path='' AS $$
 SELECT jsonb_build_object('recordId',v.record_id,'versionId',v.version_id,'projectId',v.project_id,'workstream',v.workstream,'content',v.content,'contentHash',v.content_hash,'sourceHash',v.source_hash,'sourceLocator',v.source_locator,'spaceId',v.space_id,'reviewed',true,'supersedes',v.supersedes)
$$;

CREATE FUNCTION ob1_scoped_internal.payload_hash(p jsonb) RETURNS text
LANGUAGE sql IMMUTABLE SECURITY INVOKER SET search_path='' AS $$
 SELECT encode(sha256(convert_to((p - 'embedding' - 'embeddingReceiptId' - 'payloadHash')::text,'UTF8')),'hex')
$$;

CREATE FUNCTION ob1_scoped_internal.validate_capture(p jsonb) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
BEGIN
 PERFORM ob1_scoped_internal.authorise(p,true);
 IF p->>'sensitivity' IS DISTINCT FROM 'non_sensitive' OR
 coalesce(length(p->>'content'),0) NOT BETWEEN 1 AND 16000 OR
 coalesce(p->>'eventId','')='' OR coalesce(p->>'knowledgeId','')='' OR
 coalesce(p->>'sourceHash','') !~ '^[a-f0-9]{64}$' OR coalesce(p->>'sourceLocator','')='' OR
 p->>'contentHash' IS DISTINCT FROM encode(sha256(convert_to(p->>'content','UTF8')),'hex') OR
 NOT EXISTS(SELECT 1 FROM public.ob1_scoped_spaces s WHERE s.space_id=p->>'spaceId' AND s.digest=p->>'spaceDigest') OR
 NOT EXISTS(SELECT 1 FROM public.ob1_scoped_reviews r JOIN public.ob1_scoped_members m ON m.project_id=r.project_id AND m.user_id=r.approved_by AND m.role='reviewer'
  WHERE r.review_id=(p->>'reviewId')::uuid AND r.project_id=(p->>'projectId')::uuid AND r.workstream=p->>'workstream' AND r.knowledge_id=p->>'knowledgeId' AND r.source_hash=p->>'sourceHash' AND r.content_hash=p->>'contentHash' AND r.source_locator=p->>'sourceLocator' AND r.space_id=p->>'spaceId') THEN
  RAISE invalid_parameter_value USING MESSAGE='REVIEW_OR_MODEL_INVALID';
 END IF;
END $$;

CREATE FUNCTION public.ob1_scoped_preflight(p_request jsonb) RETURNS jsonb
LANGUAGE plpgsql SECURITY INVOKER SET search_path='' AS $$
DECLARE e public.ob1_scoped_events; v public.ob1_scoped_versions;
BEGIN
 PERFORM ob1_scoped_internal.validate_capture(p_request);
 SELECT * INTO e FROM public.ob1_scoped_events WHERE project_id=(p_request->>'projectId')::uuid AND workstream=p_request->>'workstream' AND event_id=p_request->>'eventId';
 IF FOUND THEN
  IF e.payload_hash <> ob1_scoped_internal.payload_hash(p_request) THEN RAISE invalid_parameter_value USING MESSAGE='EVENT_CONFLICT'; END IF;
  SELECT * INTO STRICT v FROM public.ob1_scoped_versions WHERE version_id=e.version_id;
  RETURN jsonb_build_object('duplicate',true,'version',ob1_scoped_internal.render(v));
 END IF;
 RETURN '{"duplicate":false}'::jsonb;
END $$;

CREATE FUNCTION ob1_scoped_internal.commit_version(p jsonb) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE prior jsonb; r public.ob1_scoped_records; v public.ob1_scoped_versions; vid uuid:=gen_random_uuid(); vec public.vector(384);
BEGIN
 -- The privileged function checks the original authenticated identity itself.
 PERFORM ob1_scoped_internal.validate_capture(p);
 PERFORM pg_advisory_xact_lock(hashtextextended((p->>'projectId')||'/'||(p->>'workstream')||'/'||(p->>'knowledgeId'),0));
 prior:=public.ob1_scoped_preflight(p);
 IF (prior->>'duplicate')::boolean THEN RETURN prior->'version'; END IF;
 BEGIN
  vec:=(p->'embedding')::text::public.vector(384);
  IF public.vector_norm(vec)=0 THEN RAISE invalid_parameter_value USING MESSAGE='VECTOR_INVALID'; END IF;
 EXCEPTION WHEN OTHERS THEN RAISE invalid_parameter_value USING MESSAGE='VECTOR_INVALID'; END;
 IF NOT EXISTS(SELECT 1 FROM public.ob1_scoped_embeddings e WHERE e.receipt_id=(p->>'embeddingReceiptId')::uuid
  AND e.project_id=(p->>'projectId')::uuid AND e.workstream=p->>'workstream' AND e.content_hash=p->>'contentHash'
  AND e.space_id=p->>'spaceId' AND e.embedding OPERATOR(public.=) vec) THEN
  RAISE invalid_parameter_value USING MESSAGE='EMBEDDING_RECEIPT_REQUIRED';
 END IF;
 SELECT * INTO r FROM public.ob1_scoped_records WHERE project_id=(p->>'projectId')::uuid AND workstream=p->>'workstream' AND knowledge_id=p->>'knowledgeId' FOR UPDATE;
 IF FOUND THEN
  IF r.current_version::text IS DISTINCT FROM p->>'expectedVersion' THEN RAISE serialization_failure USING MESSAGE='STALE_VERSION'; END IF;
  UPDATE public.ob1_scoped_records SET current_version=vid,revision=revision+1 WHERE record_id=r.record_id;
 ELSE
  IF p->>'expectedVersion' IS NOT NULL THEN RAISE serialization_failure USING MESSAGE='STALE_VERSION'; END IF;
  INSERT INTO public.ob1_scoped_records(project_id,workstream,knowledge_id,current_version,revision)
   VALUES((p->>'projectId')::uuid,p->>'workstream',p->>'knowledgeId',vid,1) RETURNING * INTO r;
 END IF;
 INSERT INTO public.ob1_scoped_versions(version_id,record_id,project_id,workstream,content,content_hash,source_hash,source_locator,review_id,space_id,embedding,supersedes,created_by)
 VALUES(vid,r.record_id,r.project_id,r.workstream,p->>'content',p->>'contentHash',p->>'sourceHash',p->>'sourceLocator',(p->>'reviewId')::uuid,p->>'spaceId',vec,CASE WHEN r.current_version=vid THEN NULL ELSE r.current_version END,auth.uid()) RETURNING * INTO v;
 INSERT INTO public.ob1_scoped_events VALUES(r.project_id,r.workstream,p->>'eventId',ob1_scoped_internal.payload_hash(p),vid);
 RETURN ob1_scoped_internal.render(v);
END $$;

CREATE FUNCTION public.ob1_scoped_commit(p_request jsonb) RETURNS jsonb
LANGUAGE sql SECURITY INVOKER SET search_path='' AS $$ SELECT ob1_scoped_internal.commit_version(p_request) $$;

CREATE FUNCTION public.ob1_scoped_fetch(p_request jsonb) RETURNS jsonb
LANGUAGE plpgsql SECURITY INVOKER SET search_path='' AS $$
DECLARE v public.ob1_scoped_versions;
BEGIN
 PERFORM ob1_scoped_internal.authorise(p_request);
 SELECT ver.* INTO STRICT v FROM public.ob1_scoped_records r JOIN public.ob1_scoped_versions ver ON ver.record_id=r.record_id
 WHERE r.record_id=(p_request->>'id')::uuid AND r.project_id=(p_request->>'projectId')::uuid AND r.workstream=p_request->>'workstream'
 AND ver.version_id=coalesce((p_request->>'versionId')::uuid,r.current_version);
 RETURN ob1_scoped_internal.render(v);
END $$;

CREATE FUNCTION public.ob1_scoped_list(p_request jsonb) RETURNS jsonb
LANGUAGE plpgsql SECURITY INVOKER SET search_path='' AS $$
DECLARE result jsonb; lim integer:=coalesce((p_request->>'limit')::integer,10);
BEGIN
 PERFORM ob1_scoped_internal.authorise(p_request);
 IF lim NOT BETWEEN 1 AND 100 THEN RAISE invalid_parameter_value USING MESSAGE='LIMIT_INVALID'; END IF;
 SELECT coalesce(jsonb_agg(item),'[]'::jsonb) INTO result FROM (
  SELECT ob1_scoped_internal.render(v) item FROM public.ob1_scoped_records r JOIN public.ob1_scoped_versions v ON v.version_id=r.current_version
  WHERE r.project_id=(p_request->>'projectId')::uuid AND r.workstream=p_request->>'workstream' AND v.space_id=p_request->>'spaceId'
  ORDER BY r.record_id LIMIT lim
 ) matches;
 RETURN result;
END $$;

CREATE FUNCTION public.ob1_scoped_search(p_request jsonb) RETURNS jsonb
LANGUAGE plpgsql SECURITY INVOKER SET search_path='' AS $$
DECLARE result jsonb; vec public.vector(384); lim integer:=coalesce((p_request->>'limit')::integer,10);
BEGIN
 PERFORM ob1_scoped_internal.authorise(p_request);
 IF lim NOT BETWEEN 1 AND 100 THEN RAISE invalid_parameter_value USING MESSAGE='LIMIT_INVALID'; END IF;
 vec:=(p_request->'queryVector')::text::public.vector(384);
 IF public.vector_norm(vec)=0 THEN RAISE invalid_parameter_value USING MESSAGE='VECTOR_INVALID'; END IF;
 WITH scoped AS MATERIALIZED (
  SELECT v.* FROM public.ob1_scoped_records r JOIN public.ob1_scoped_versions v ON v.version_id=r.current_version
  WHERE r.project_id=(p_request->>'projectId')::uuid AND r.workstream=p_request->>'workstream' AND v.space_id=p_request->>'spaceId'
 ), ranked AS (
  SELECT ob1_scoped_internal.render(s::public.ob1_scoped_versions) item FROM scoped s ORDER BY s.embedding OPERATOR(public.<=>) vec,s.version_id LIMIT lim
 ) SELECT coalesce(jsonb_agg(item),'[]'::jsonb) INTO result FROM ranked;
 RETURN result;
END $$;

REVOKE ALL ON FUNCTION ob1_scoped_internal.authorise(jsonb,boolean), ob1_scoped_internal.render(public.ob1_scoped_versions), ob1_scoped_internal.payload_hash(jsonb), ob1_scoped_internal.validate_capture(jsonb), ob1_scoped_internal.commit_version(jsonb), public.ob1_scoped_preflight(jsonb), public.ob1_scoped_commit(jsonb), public.ob1_scoped_fetch(jsonb), public.ob1_scoped_list(jsonb), public.ob1_scoped_search(jsonb) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION ob1_scoped_internal.authorise(jsonb,boolean), ob1_scoped_internal.render(public.ob1_scoped_versions), ob1_scoped_internal.payload_hash(jsonb), ob1_scoped_internal.validate_capture(jsonb), ob1_scoped_internal.commit_version(jsonb), public.ob1_scoped_preflight(jsonb), public.ob1_scoped_commit(jsonb), public.ob1_scoped_fetch(jsonb), public.ob1_scoped_list(jsonb), public.ob1_scoped_search(jsonb) TO authenticated;
COMMIT;
