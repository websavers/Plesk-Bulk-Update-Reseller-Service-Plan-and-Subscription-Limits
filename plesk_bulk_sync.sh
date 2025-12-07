#!/bin/bash

function main {

    [ "$(which plesk)" != "/sbin/plesk" ] && echo "Plesk not installed... exiting" && exit 1

    while test $# -gt 0
    do
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
            --sync-all-subscriptions)
            sync_all_subscriptions
            ;;
        esac

        case "$1" in
            --update)
                #ex: --update mbox_quota > 5G
                #ex: --update oversell = false
                update $2 $3 $4
                ;;
        esac

        shift

    done

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

function update {

    # Mail quota
    PARAMETER=$2
    COMPARE=$3
    VALUE=$4
    #VALUE="5242880" #5G

    # Obtain all (not-reseller) service plans owned by resellers
    plesk db -Ne "SELECT Templates.name,clients.login FROM Templates LEFT JOIN clients ON Templates.owner_id=clients.id WHERE clients.type='reseller';" | 
    while read -r result ; do
        plan_name=$(echo $result | cut -f1 -d' ')
        reseller_login=$(echo $result | cut -f2 -d' ')

        echo "Checking service plan '$plan_name' owned by '$reseller_login'..."
        existing=$(plesk bin service_plan -x "$plan_name" -owner "$reseller_login" | sed -nE "s/^.*<service-plan-item name=\"$PARAMETER\">(.*)<.*$/\1/p")
        if (( $existing $COMPARE $VALUE )); then
            echo "Updating service plan '$plan_name' owned by '$reseller_login'... replacing current=$existing with new=$VALUE"
            plesk bin service_plan --update "$plan_name" -owner "$reseller_login" -$PARAMETER ${VALUE}K
        else
            echo "Skipping because $existing is not $COMPARE $VALUE"
        fi
    done

    #plesk bin mail -u JDoe@example.com -mbox_quota 50M
}

# Call main and pass in params
main "$@"; exit