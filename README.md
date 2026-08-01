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

## Database and UI fixtures

```powershell
.\database\dev-db.ps1 up
.\database\qa-db-reset.ps1
.\database\seed-ui.ps1
```

`qa-db-reset.ps1` refuses to clean a target other than the exact local QA URL.

## Postman E2E and UI development

```powershell
.\postman\e2e-local.ps1
.\postman\seed-playground.ps1
.\postman\show-e2e-flow.ps1
```

The Postman Desktop import files are in the service repository:

- `postman\generated\doc-exchange-playground.postman_collection.json`
- `postman\environments\local-qa.postman_environment.json`

## Development audits

```powershell
python .\development\audit-request-validation.py
python .\development\extract-dto-fields.py
```
