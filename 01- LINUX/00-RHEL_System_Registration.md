# RHEL System Registration
[Reference Page](https://access.redhat.com/documentation/en-us/subscription_central/2023/html-single/getting_started_with_rhel_system_registration)

## Register your RHEL with your Red Hat Account
```bash
subscription-manager register --username=<username> --password=<password>
```
## Attach your Subscription
```bash
subscription-manager attach --auto
```

## Register your RHEL And Attach your Subscription in one step
```bash
subscription-manager register --username=<username> --password=<password> --auto-attach
```

## Validate the current Subscription
```bash
subscription-manager status
```

## List your Subscriptions
```bash
subscription-manager list 

subscription-manager list --consumed
```
