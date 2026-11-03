\set ON_ERROR_STOP on
BEGIN;
INSERT INTO public.ob1_scoped_projects VALUES ('00000000-0000-4000-8000-000000000001','fixture-a'),('00000000-0000-4000-8000-000000000002','fixture-b');
INSERT INTO public.ob1_scoped_members VALUES
 ('00000000-0000-4000-8000-000000000001','00000000-0000-4000-8000-000000000011','writer'),
 ('00000000-0000-4000-8000-000000000002','00000000-0000-4000-8000-000000000012','writer'),
 ('00000000-0000-4000-8000-000000000001','00000000-0000-4000-8000-000000000013','reviewer');
INSERT INTO public.ob1_scoped_spaces VALUES ('fixture-space-v1',repeat('a',64),384);
INSERT INTO public.ob1_scoped_reviews VALUES
 ('00000000-0000-4000-8000-000000000021','00000000-0000-4000-8000-000000000001','fixture-a','fixture-source',repeat('b',64),encode(digest('Reviewed fixture one.','sha256'),'hex'),'fixture/1','fixture-space-v1','00000000-0000-4000-8000-000000000013'),
 ('00000000-0000-4000-8000-000000000022','00000000-0000-4000-8000-000000000001','fixture-a','fixture-source',repeat('b',64),encode(digest('Reviewed fixture two.','sha256'),'hex'),'fixture/1','fixture-space-v1','00000000-0000-4000-8000-000000000013');
INSERT INTO public.ob1_scoped_embeddings VALUES
 ('00000000-0000-4000-8000-000000000031','00000000-0000-4000-8000-000000000001','fixture-a',encode(digest('Reviewed fixture one.','sha256'),'hex'),'fixture-space-v1',('['||'1,'||repeat('0,',382)||'0]')::public.vector(384)),
 ('00000000-0000-4000-8000-000000000032','00000000-0000-4000-8000-000000000001','fixture-a',encode(digest('Reviewed fixture two.','sha256'),'hex'),'fixture-space-v1',('['||'1,'||repeat('0,',382)||'0]')::public.vector(384));
SET LOCAL ROLE authenticated;
SET LOCAL request.jwt.claim.sub = '00000000-0000-4000-8000-000000000011';
DO $$
DECLARE p jsonb; first jsonb; second jsonb; replay jsonb; hit jsonb;
BEGIN
 p := jsonb_build_object('projectId','00000000-0000-4000-8000-000000000001','workstream','fixture-a','knowledgeId','fixture-source','eventId','event-1','sourceHash',repeat('b',64),'sourceLocator','fixture/1','content','Reviewed fixture one.','contentHash',encode(digest('Reviewed fixture one.','sha256'),'hex'),'reviewId','00000000-0000-4000-8000-000000000021','expectedVersion',null,'spaceId','fixture-space-v1','spaceDigest',repeat('a',64),'sensitivity','non_sensitive');
 IF (public.ob1_scoped_preflight(p)->>'duplicate')::boolean THEN RAISE EXCEPTION 'unexpected duplicate'; END IF;
 first := public.ob1_scoped_commit(p || jsonb_build_object('embeddingReceiptId','00000000-0000-4000-8000-000000000031','embedding',array_prepend(1, array_fill(0, ARRAY[383]))));
 replay := public.ob1_scoped_commit(p || jsonb_build_object('embeddingReceiptId','00000000-0000-4000-8000-000000000031','embedding',array_prepend(1, array_fill(0, ARRAY[383]))));
 IF first <> replay OR (SELECT count(*) FROM public.ob1_scoped_versions) <> 1 THEN RAISE EXCEPTION 'duplicate mutated state'; END IF;
 IF NOT (public.ob1_scoped_preflight(p)->>'duplicate')::boolean THEN RAISE EXCEPTION 'preflight missed duplicate'; END IF;
 BEGIN
  PERFORM public.ob1_scoped_preflight(p || jsonb_build_object('content','Reviewed fixture two.','contentHash',encode(digest('Reviewed fixture two.','sha256'),'hex'),'reviewId','00000000-0000-4000-8000-000000000022'));
  RAISE EXCEPTION 'event conflict accepted';
 EXCEPTION WHEN SQLSTATE '22023' THEN
  IF SQLERRM <> 'EVENT_CONFLICT' THEN RAISE; END IF;
 END;
 BEGIN
  PERFORM public.ob1_scoped_commit(p || '{"eventId":"invalid","spaceDigest":"wrong","embedding":[1]}'::jsonb);
  RAISE EXCEPTION 'invalid space accepted';
 EXCEPTION WHEN SQLSTATE '22023' THEN NULL; END;
 p := p || jsonb_build_object('eventId','event-2','content','Reviewed fixture two.','contentHash',encode(digest('Reviewed fixture two.','sha256'),'hex'),'reviewId','00000000-0000-4000-8000-000000000022','expectedVersion',first->>'versionId');
 BEGIN
  PERFORM public.ob1_scoped_commit(p || jsonb_build_object('embedding',array_prepend(1, array_fill(0, ARRAY[383]))));
  RAISE EXCEPTION 'invented embedding accepted';
 EXCEPTION WHEN SQLSTATE '22023' THEN
  IF SQLERRM <> 'EMBEDDING_RECEIPT_REQUIRED' THEN RAISE; END IF;
 END;
 second := public.ob1_scoped_commit(p || jsonb_build_object('embeddingReceiptId','00000000-0000-4000-8000-000000000032','embedding',array_prepend(1, array_fill(0, ARRAY[383]))));
 IF second->>'supersedes' <> first->>'versionId' THEN RAISE EXCEPTION 'supersedes lost'; END IF;
 hit := public.ob1_scoped_search(p || jsonb_build_object('queryVector',array_prepend(1, array_fill(0, ARRAY[383])),'limit',10));
 IF jsonb_array_length(hit) <> 1 OR hit->0->>'versionId' <> second->>'versionId' THEN RAISE EXCEPTION 'search leaked old version'; END IF;
 IF (public.ob1_scoped_fetch(p || jsonb_build_object('id',first->>'recordId','versionId',first->>'versionId')))->>'content' <> 'Reviewed fixture one.' THEN RAISE EXCEPTION 'history lost'; END IF;
 BEGIN
  PERFORM public.ob1_scoped_commit(p || jsonb_build_object('eventId','event-3','expectedVersion',first->>'versionId','embeddingReceiptId','00000000-0000-4000-8000-000000000032','embedding',array_prepend(1, array_fill(0, ARRAY[383]))));
  RAISE EXCEPTION 'stale write accepted';
 EXCEPTION WHEN SQLSTATE '40001' THEN NULL; END;
 BEGIN
  PERFORM public.ob1_scoped_list(p || '{"projectId":"00000000-0000-4000-8000-000000000002"}'::jsonb);
  RAISE EXCEPTION 'cross-project read accepted';
 EXCEPTION WHEN insufficient_privilege THEN NULL; END;
 BEGIN
  PERFORM public.ob1_scoped_fetch(p || '{"workstream":"other"}'::jsonb);
  RAISE EXCEPTION 'wrong workstream accepted';
 EXCEPTION WHEN no_data_found THEN NULL; END;
 BEGIN
  INSERT INTO public.ob1_scoped_projects VALUES (gen_random_uuid(),'forged');
  RAISE EXCEPTION 'direct write accepted';
 EXCEPTION WHEN insufficient_privilege THEN NULL; END;
 IF (SELECT count(*) FROM public.ob1_scoped_versions) <> 2 THEN RAISE EXCEPTION 'failed transaction leaked row'; END IF;
END $$;
RESET ROLE;
SET LOCAL ROLE anon;
DO $$ BEGIN
 BEGIN
  PERFORM public.ob1_scoped_list('{}'::jsonb);
  RAISE EXCEPTION 'anonymous access accepted';
 EXCEPTION WHEN insufficient_privilege THEN NULL; END;
END $$;
RESET ROLE;
SET CONSTRAINTS ALL IMMEDIATE;
ROLLBACK;
\echo 'Scoped SQL transaction, access, duplicate and supersession checks passed'
