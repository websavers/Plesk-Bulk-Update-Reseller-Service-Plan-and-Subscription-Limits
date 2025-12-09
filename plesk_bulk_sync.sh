#!/bin/bash

TMP_SUBSCRIPTION_LIST=/tmp/plesk_subscriptions.txt

function main {

    [ "$(which plesk)" != "/sbin/plesk" ] && echo "Plesk not installed... exiting" && exit 1

    #while test $# -gt 0
    #do
        echo "$1 parameter provided."

        case "$1" in
            --sync-resellers)
            get_reseller_subscriptions && sync_subscriptions
            if [ "$?" -eq 0 ]; then 
                sync_resellers
            else 
                echo "[$?] Errors found during subscriptions sync. See output above for details. Fix them, then try again."
            fi
            ;;
        esac        

        case "$1" in
            --sync-reseller-subscriptions)
            if [ "$2" -eq "--only-locked" ]; then 
                get_reseller_subscriptions "only-locked"
            else
                get_reseller_subscriptions
            fi
            ;;
        esac

        case "$1" in
            --update-reseller-owned-service-plans)
                update_reseller_owned_service_plans $2 $3
                ;;
        esac

        case "$1" in
            --update-reseller-owned-subscriptions)
                update_reseller_owned_subscriptions $2 $3
                ;;
        esac

        # This is the only option that isn't reseller specific
        case "$1" in
            --sync-all-subscriptions)
            get_all_locked_subscriptions && sync_subscriptions
            ;;
        esac

        #shift

    #done

    #Cleanup
    rm -f $TMP_SUBSCRIPTION_LIST

    exit 0

}

# https://support.plesk.com/hc/en-us/articles/12377770549015-How-to-synchronize-locked-subscriptions-with-their-service-plans

# This refers to hosting subscriptions owned by resellers
function get_reseller_subscriptions {
    if [ "$1" == "only-locked" ]; then 
        plesk db -sNe "SELECT name FROM domains d INNER JOIN Subscriptions s ON d.id=s.object_id INNER JOIN clients c ON d.cl_id=c.id WHERE d.webspace_id=0 AND s.object_type='domain' AND s.locked='true' AND c.type='reseller'" > $TMP_SUBSCRIPTION_LIST
    else
        plesk db -sNe "SELECT name FROM domains d INNER JOIN Subscriptions s ON d.id=s.object_id INNER JOIN clients c ON d.cl_id=c.id WHERE d.webspace_id=0 AND s.object_type='domain' AND c.type='reseller'" > $TMP_SUBSCRIPTION_LIST
    fi    
}

function get_all_locked_subscriptions {
    plesk db -sNe "SELECT name FROM domains d INNER JOIN Subscriptions s ON d.id=s.object_id WHERE d.webspace_id=0 AND s.object_type='domain' AND s.locked='true'" > $TMP_SUBSCRIPTION_LIST
}

function sync_subscriptions {

    error=0

    #unlock and sync
    for domain in `cat $TMP_SUBSCRIPTION_LIST`
    do
        echo "Unlocking subscription with primary domain: $domain"
        plesk bin subscription --unlock-subscription $domain
        [ $? -gt 0 ] && error=1
        echo "Syncing subscription with primary domain: $domain"
        plesk bin subscription --sync-subscription $domain
        [ $? -gt 0 ] && error=1
    done

    [ $error -gt 0 ] && return 1

    # Check for any that failed (won't work for resellers, so ignore this check)
    #echo "The following domains did not sync:"
    #plesk db -sNe "SELECT name FROM domains d INNER JOIN Subscriptions s ON d.id=s.object_id WHERE d.webspace_id=0 AND s.object_type='domain' AND s.synchronized='false'"

}

# this refers to resellers themselves (ie: their 'subscription' created out of a reseller service plan)
function sync_resellers {

    plesk db -sNe "SELECT c.login FROM clients c INNER JOIN Subscriptions s ON c.id=s.object_id WHERE s.object_type='client' AND s.locked='true' AND c.type='reseller'" | 
    while read -r r_username
    do
        echo "Trying to sync reseller $r_username..."
        plesk bin reseller --unlock-subscription $r_username
        plesk bin reseller --sync-subscription $r_username
        echo ""
    done

}

function update_reseller_owned_service_plans {

    PARAMETER=$1
    VALUE=$2
    
    echo "Parameter: $PARAMETER, Value: $VALUE"

    echo "Getting service plans owned by resellers..."
    # Obtain all service plans owned by resellers (Note: these are not reseller service plans)
    # sed swaps tabs for commas, because bash var/output swaps tabs for 5 spaces, which isn't helpful
    plesk db -Ne "SELECT Templates.name,clients.login FROM Templates LEFT JOIN clients ON Templates.owner_id=clients.id WHERE clients.type='reseller';" | sed 's/\t/,/g' | 
    while read -r result
    do

        plan_name=$(echo "$result" | cut -f1 -d',')
        reseller_login=$(echo "$result" | cut -f2 -d',')

        echo "Examining service plan '$plan_name' owned by '$reseller_login'..."

        if [ "$VALUE" == "" ]; then
            # Get Reseller Plan Info
            reseller_service_plan_name=$(plesk bin reseller -i $reseller_login | sed -nE 's/^.*service plan "(.*)" of.*$/\1/p')
            VALUE=$(plesk bin reseller_plan -x "$reseller_service_plan_name" | sed -nE "s/^.*<service-plan-item name=\"$PARAMETER\">(.*)<.*$/\1/p")
        fi

        COMPARE_WITH=$(get_comparison $PARAMETER $VALUE)

        existing=$(plesk bin service_plan -x "$plan_name" -owner "$reseller_login" | sed -nE "s/^.*<service-plan-item name=\"$PARAMETER\">(.*)<.*$/\1/p")

        if [ "$existing" $COMPARE_WITH ] || [ "$existing" = "-1" ]; then
            echo "Updating service plan '$plan_name' owned by '$reseller_login'... replacing current=$existing with new=$VALUE"
            plesk bin service_plan --update "$plan_name" -owner "$reseller_login" -$PARAMETER $VALUE
        else
            echo "Skipping because $existing is not $COMPARE_WITH ($VALUE)"
        fi

    done

}

# The goal here is to target subscriptions that are not created from service plans
# Any that are tied to service plans will already have had the parameter updated in the above part
function update_reseller_owned_subscriptions {

    PARAMETER=$1
    VALUE=$2

    echo "Parameter: $PARAMETER, Value: $VALUE"

    echo "Getting subscriptions owned by resellers..."
    get_reseller_subscriptions
    for domain in `cat $TMP_SUBSCRIPTION_LIST`
    do

        echo "Examining subscription with primary domain: $domain..."

        subscription_id=$(plesk bin subscription -i "$domain" | sed -nE 's/^Domain ID:\s+(.*)$/\1/p')

        existing=$(plesk db -Ne "SELECT Limits.value FROM Limits LEFT JOIN SubscriptionProperties ON Limits.id=SubscriptionProperties.value WHERE Limits.limit_name='$PARAMETER' AND SubscriptionProperties.subscription_id=$subscription_id AND SubscriptionProperties.name='limitsId';" | sed 's/\t/,/g')
        if [ "$existing" = "" ]; then
            echo "Skipping $domain - does not have separate config from parent service plan"
            continue
        fi

        if [ "$VALUE" = "" ]; then
            # Get Reseller Plan Info
            reseller_login=$(plesk bin subscription -i "$domain" | sed -nE "s/^Owner's contact name:.*\((.*)\)$/\1/p")
            reseller_service_plan_name=$(plesk bin reseller -i $reseller_login | sed -nE 's/^.*service plan "(.*)" of.*$/\1/p')
            VALUE=$(plesk bin reseller_plan -x "$reseller_service_plan_name" | sed -nE "s/^.*<service-plan-item name=\"$PARAMETER\">(.*)<.*$/\1/p")
        fi

        COMPARE_WITH=$(get_comparison $PARAMETER $VALUE)

        if [ "$existing" $COMPARE_WITH ] || [ "$existing" = "-1" ]; then
            echo "Updating subscription... replacing current=$existing with new=$VALUE"
            #Value is in bytes, hence the B
            plesk bin subscription_settings --update "$domain" -$PARAMETER ${VALUE}B
        else
            echo "Skipping because $existing is not $COMPARE_WITH ($VALUE)"
        fi

    done
    
}

## Helper Function ##

function get_comparison {

    local PARAMETER=$1
    local VALUE=$2
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
        COMPARE="!=" #string compare
        COMPARE_VALUE=$VALUE
    fi

    echo "$COMPARE "$COMPARE_VALUE""
}

# Call main and pass in params
main "$@"; exit