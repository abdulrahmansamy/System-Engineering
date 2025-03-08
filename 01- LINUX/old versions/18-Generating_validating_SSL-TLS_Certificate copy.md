# Generating SSL/TLS Certificate
## Generating CSR request
```bash
openssl req -new -newkey rsa:2048 -nodes -keyout domain.com.key -out domain.com.csr
```

```sh
openssl req -new -nodes -out domain.com.sa.csr -newkey rsa:2048 -keyout domain.com.sa.key -config openssl.cnf
```


vim openssl.cnf

```cnf
[req]
default_bits       = 2048
distinguished_name = req_distinguished_name
prompt             = no

[req_distinguished_name]
C  = SA
ST = RIYADH
L  = RIYADH
O  = domain
OU = Financial Services
CN = domain.com.sa
```

## Validating signed certificate

### Verify the digital signature
```
openssl verify -CAfile ca-cert.pem signed-cert.pem
```
or 
```
openssl verify -CAfile root-ca.pem -untrusted intermediate-ca.pem end-entity-cert.pem
```

### Inspect the Certificate Details
```
openssl x509 -in signed-cert.pem -text -noout
```



