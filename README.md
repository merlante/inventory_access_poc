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
curl "http://localhost:8080/content/packages"
```
## Docker
```
docker build . -t quay.io/ciam_authz/inventory_access_poc
docker run -p8080:8080 --rm quay.io/ciam_authz/inventory_access_poc
```
## Regenerate server code
`oapi-codegen -config api/server.cfg.yaml api/openapi.json`
