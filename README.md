# Reseller owned Subscriptions

Ensure consistent permissions:

bash plesk_bulk_sync.sh --update-service-plans allow_local_backups false
bash plesk_bulk_sync.sh --update-service-plans allow_account_local_backups false

Ensure consistent mailbox quota:

Note: no value means it automatically pulls the value from the parent reseller plan config
bash plesk_bulk_sync.sh --update-service-plans mbox_quota

# Reseller plans directly

bash plesk_bulk_sync.sh --sync-resellers