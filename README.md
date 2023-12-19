# PoC for validating big "join" scenarios
PoC for validating big "join" scenarios where large access data sets need to be joined on filtered, sorted and paged content data
Implement an API that mirrors the "Content" tab on console dot.

# Development
## Run inventory_access_poc with spicedb (using schema in /schema)
```
docker-compose up --build
```
Test using an endpoint like:
```
curl "http://localhost:8080/content/packages" -H "Authorization: test_user;14" -H "Use-Database-Only: true"
```
Test using an endpoint with using database only:
```
curl "http://localhost:8080/content/packages"
```
## Run REFRESH PACKAGE CACHES task
```
go build main.go
export CONTENT_POSTGRES_URI=postgres://root:toor@localhost:5432/content?sslmode=disable
export RUN_ACTION=REFRESH_PACKAGE_CACHES 
./main
```

## Docker
```
docker build . -t quay.io/ciam_authz/inventory_poc_testservice
docker run -p8080:8080 --rm quay.io/ciam_authz/inventory_poc_testservice
```
## Regenerate server code
`oapi-codegen -config api/server.cfg.yaml api/openapi.json`
