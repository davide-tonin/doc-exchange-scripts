# Doc Exchange local operations

This repository is the single home for scripts that run, seed, test, maintain,
and support local UI development of Doc Exchange. Defaults:

- service: `C:\Users\DavideTonin\IdeaProjects\doc-exchange-service`
- database migrations: `C:\Users\DavideTonin\DataGripProjects\doc-exchange-db`
- disposable PostgreSQL: `jdbc:postgresql://localhost:5433/de-db`

Every entry point accepts `-ServiceRepository` when the service checkout is elsewhere.
The service retains Postman collection sources/generated output because its integration
tests validate those files; all commands which operate them are here.

## Run and test

```powershell
.\application\run-app.ps1
.\application\test.ps1 test
.\application\openapi-smoke.ps1
```

## Stage configuration

```powershell
.\application_yaml_management\upload.ps1 -Stage qa
```

`application-qa.yaml`, `application-sandbox.yaml` and `application-prod.yaml` are the real
deployed stage documents; `upload.ps1` pushes one of them to
`s3://de-stage-configuration-7f3c91a6e4b82d50/stages/<stage>/application.yaml`.

The service reads exactly one complete literal document — no placeholders, imports, profile
overlays, anchors or defaults — and validates its raw structure before any bean is created.
An unknown key does not degrade gracefully, it aborts startup, and the failure only surfaces
on the next restart of that stage. **Add the key to `ALLOWED_FRAMEWORK_LEAF_PATHS` in the
service's `StageConfigurationPreflight` and deploy that build first, then upload.**

All three documents currently enable case-insensitive enum intake
(`spring.jackson.mapper.accept-case-insensitive-enums` and `-values`), so callers may send
`PERSON`, `person` or `Person`. Responses still emit the exact `UPPER_SNAKE_CASE` name.

## Database and UI fixtures

```powershell
.\database\dev-db.ps1 up
.\database\qa-db-reset.ps1
.\database\seed-ui.ps1
```

`qa-db-reset.ps1` refuses to clean a target other than the exact local QA URL.

`seed-ui.ps1` performs that clean reset and then fills the database with the full UI dataset
through the real public API: ten interlinked tenants with aliases, roles, POVs, shapes,
identities, grants, groups, cross-tenant shares and party groups, plus ~690 backdated documents
and mixed read cursors. Sized against the service's own caps and page sizes, so pagination, limit
alerts, lifecycle badges and cross-tenant screens all have data behind them. No email is involved:
the local QA document enables the guarded seed-echo delivery seam, while bootstrap still follows
the production path.

Every login shares one password, `UiPlayground!2026` (`-LoginPassword` to change it), and the run
writes `build\seed\seed-manifest.json` in the service repo with every id, login and achieved
count. `-Scale Fast` gives the same shape with a sixth of the rows; `-Seed` makes a run
reproducible. Implementation lives in `database\seed\`; the dataset rationale is in the service
repo at `docs\UI_SEED_DATASET.md`.

## Postman E2E and UI development

```powershell
.\postman\refresh.ps1 -UseTestExport
.\postman\e2e-local.ps1
.\postman\seed-playground.ps1
.\postman\show-e2e-flow.ps1
```

`refresh.ps1` regenerates the collections from the service's own OpenAPI documents — with
`-UseTestExport` it runs `PostmanOpenApiExportIT` to produce them, otherwise it fetches them
from a running instance. Run it after any request-contract change: the generated collections
carry literal request bodies, so a renamed enum constant or schema leaves them sending values
the API now rejects, and the e2e run fails on the stale body rather than on a real defect.

The Postman Desktop import files are in the service repository:

- `postman\generated\doc-exchange-playground.postman_collection.json`
- `postman\environments\local-qa.postman_environment.json`

## Development audits

```powershell
python .\development\audit-request-validation.py
python .\development\extract-dto-fields.py
```
