# RHEL Enable Repos

[Reference Page](https://access.redhat.com/solutions/265523)

### List all Repos
```
yum repolist all
```

## Using Subscription-Manager
### List all Repos
```
subscription-manager repos --list
```


### Enable a specific Red Hat repository:
```
subscription-manager repos --enable=<Repo Name>
```

### Disable a specific Red Hat repository:
```
subscription-manager repos --disable=<Repo Name>
```

## Using Yum-Utils provided yum-config-manager:
```
yum install -y yum-utils
```

### Enable a specific Red Hat repository:
```
yum-config-manager --enable <repo-id>
```

### Disable a specific Red Hat repository:
```
yum-config-manager --disable <repo-id>
```

## Enable a repository for a single yum transaction
```
yum install rubygems --enablerepo=rhel-6-server-optional-rpms
```