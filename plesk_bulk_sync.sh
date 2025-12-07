#!/bin/bash

function main {

    [ "$(which plesk)" != "/sbin/plesk" ] && echo "Plesk not installed... exiting" && exit 1

    #while test $# -gt 0
    #do
        echo "$1 parameter provided."

        case "$1" in
            --sync-resellers)
            sync_reseller_subscriptions
            if [ "$?" -eq 0 ]; then 
                sync_resellers
            else 
                echo "[$?] Errors found during subscriptions sync. See output above for details. Fix them, then try again."
            fi
            ;;
        esac        

        case "$1" in
            --sync-reseller-subscriptions)
            sync_reseller_subscriptions
            ;;
        esac

        case "$1" in
            --update-service-plans)
                #ex: --update mbox_quota > 5G
                #ex: --update oversell = false
                update_subscription_parameter $2 $3
                ;;
        esac

        # This is the only option that isn't reseller specific
        case "$1" in
            --sync-all-subscriptions)
            sync_all_subscriptions
            ;;
        esac

        #shift

    #done

    exit 0

}

# https://support.plesk.com/hc/en-us/articles/12377770549015-How-to-synchronize-locked-subscriptions-with-their-service-plans

function sync_reseller_subscriptions {
    tmpfile=/tmp/locked_subscriptions.txt
    plesk db -sNe "SELECT name FROM domains d INNER JOIN Subscriptions s ON d.id=s.object_id INNER JOIN clients c ON d.cl_id=c.id WHERE d.webspace_id=0 AND s.object_type='domain' AND s.locked='true' AND c.type='reseller'" > $tmpfile
    [ -e "$tmpfile" ] && [ -s "$tmpfile" ] && sync_subscriptions $tmpfile
    echo $?
}

function sync_all_subscriptions {
    tmpfile=/tmp/locked_subscriptions.txt
    plesk db -sNe "SELECT name FROM domains d INNER JOIN Subscriptions s ON d.id=s.object_id WHERE d.webspace_id=0 AND s.object_type='domain' AND s.locked='true'" > /tmp/locked_subscriptions.txt
    [ -e "$tmpfile" ] && [ -s "$tmpfile" ] && sync_subscriptions $tmpfile
    echo $?
}

function sync_subscriptions {

    sub_list=$1
    error=0

    #unlock and sync
    for domain in `cat $sub_list`
    do
        echo "Trying to sync reseller subscription with primary domain: $domain"
        plesk bin subscription --unlock-subscription $domain
        [ $? -gt 0 ] && error=1
        plesk bin subscription --sync-subscription $domain
        [ $? -gt 0 ] && error=1
    done

    [ $error -gt 0 ] && return 1

    # Check for any that failed (won't work for resellers, so ignore this check)
    #echo "The following domains did not sync:"
    #plesk db -sNe "SELECT name FROM domains d INNER JOIN Subscriptions s ON d.id=s.object_id WHERE d.webspace_id=0 AND s.object_type='domain' AND s.synchronized='false'"

}

function sync_resellers {

    plesk db -Ne "SELECT clients.login FROM clients WHERE clients.type='reseller';" | 
    while read -r r_username
    do
        echo "Trying to sync reseller $r_username..."
        plesk bin reseller --unlock-subscription $r_username -force
        plesk bin reseller --sync-subscription $r_username -force
        echo ""
    done

}

## 
# Example Usage:
# bash plesk_bulk_sync.sh --update mbox_quota 5G
# The following will sync the parameter to the parent reseller plan value
# bash plesk_bulk_sync.sh --update mbox_quota
##

function update_subscription_parameter {

    PARAMETER=$1
    VALUE=$2
    SYNC_TO_RESELLER_SERVICE_PLAN=0
    
    echo "Parameter: $PARAMETER, Value: $VALUE"

    size_parameters=("mbox_quota" "disk_space" "max_traffic")
    if [[ " ${size_parameters[@]} " =~ " $PARAMETER " ]]; then
        COMPARE="-gt"
        if [[ "$VALUE" =~ ^[0-9]+G$ ]]; then
            COMPARE_VALUE=$(echo "$VALUE" | sed -nE 's/^([[:digit:]]+)G$/\1/p')
            COMPARE_VALUE=$((COMPARE_VALUE * 1024 * 1024 * 1024))
        elif [[ "$VALUE" =~ ^[0-9]+M ]]; then
            COMPARE_VALUE=$(echo "$VALUE" | sed -nE 's/^([[:digit:]]+)M$/\1/p')
            COMPARE_VALUE=$((COMPARE_VALUE * 1024 * 1024))
        elif [[ "$VALUE" =~ ^[0-9]+K ]]; then
            COMPARE_VALUE=$(echo "$VALUE" | sed -nE 's/^([[:digit:]]+)K$/\1/p')
            COMPARE_VALUE=$((COMPARE_VALUE * 1024))
        else
            COMPARE_VALUE=$VALUE
        fi
    else
        COMPARE="-eq"
        COMPARE_VALUE=$VALUE
    fi

    #echo $COMPARE_VALUE ###DEBUG


    # Obtain all service plans owned by resellers (Note: these are not reseller service plans)
    # sed swaps tabs for commas, because bash var/output swaps tabs for 5 spaces, which isn't helpful
    plesk db -Ne "SELECT Templates.name,clients.login FROM Templates LEFT JOIN clients ON Templates.owner_id=clients.id WHERE clients.type='reseller';" | sed 's/\t/,/g' | 
    while read -r result ; do

        plan_name=$(echo "$result" | cut -f1 -d',')
        reseller_login=$(echo "$result" | cut -f2 -d',')

        echo "Examining service plan '$plan_name' owned by '$reseller_login'..."

        if [ "$VALUE" == "" ]; then
            # Get Reseller Plan Info
            reseller_service_plan_name=$(plesk bin reseller -i $reseller_login | sed -nE 's/^.*service plan "(.*)" of.*$/\1/p')
            COMPARE_VALUE=$(plesk bin reseller_plan -x "$reseller_service_plan_name" | sed -nE "s/^.*<service-plan-item name=\"$PARAMETER\">(.*)<.*$/\1/p")
        fi

        existing=$(plesk bin service_plan -x "$plan_name" -owner "$reseller_login" | sed -nE "s/^.*<service-plan-item name=\"$PARAMETER\">(.*)<.*$/\1/p")

        if [ "$existing" $COMPARE "$COMPARE_VALUE" ] || [ "$existing" -eq "-1" ]; then
            echo "Updating service plan '$plan_name' owned by '$reseller_login'... replacing current=$existing with new=$VALUE"
            plesk bin service_plan --update "$plan_name" -owner "$reseller_login" -$PARAMETER $VALUE
        else
            echo "Skipping because $existing is not $COMPARE $COMPARE_VALUE ($VALUE)"
        fi

    done

    #plesk bin mail -u JDoe@example.com -mbox_quota 50M
}

# Call main and pass in params
main "$@"; exit