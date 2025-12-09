# Reseller owned Subscriptions and Service Plans

Ensure consistent permissions:
bash plesk_bulk_sync.sh --update-reseller-owned-service-plans allow_local_backups false
bash plesk_bulk_sync.sh --update-reseller-owned-subscriptions allow_local_backups false

bash plesk_bulk_sync.sh --update-reseller-owned-service-plans allow_account_local_backups false
bash plesk_bulk_sync.sh --update-reseller-owned-subscriptions allow_account_local_backups false

Ensure consistent mailbox quota using parent reseller plan value:

bash plesk_bulk_sync.sh --update-reseller-owned-service-plans mbox_quota
bash plesk_bulk_sync.sh --update-reseller-owned-subscriptions mbox_quota 

Ensure consistent mailbox quota using specified value:

bash plesk_bulk_sync.sh --update-reseller-owned-service-plans mbox_quota 5G
bash plesk_bulk_sync.sh --update-reseller-owned-subscriptions mbox_quota 5G

# Reseller plans directly
bash plesk_bulk_sync.sh --sync-resellers