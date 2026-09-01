# MikroTik RouterOS Dynamic DNS Update Script for Firestorm API
# v2: Quick-Check via DNS-Resolve zuerst; API wird nur angefragt, wenn ein Update noetig ist.
#     old_data fuer den PUT kommt weiterhin aus der API (autoritativ), nicht aus dem DNS-Resolve.

# Initialize variables with default / standard values
:local apiUser "api-x-user"
:local apiKey "api-x-key"
:local zoneId ""
:local recordName "subdomain.domain.ltd"
:local subDomain "subdomain"
:local recordType "A"
:local wanInterface "ethernet1"
:local ttl "60"
# Externe Resolver fuer den Quick-Check (nicht der Router-Cache); dnsServer2 ist Fallback
:local dnsServer "1.1.1.1"
:local dnsServer2 "9.9.9.9"

:local currentIp ""
:local dnsIp ""
:local oldIp ""

# Sanitize recordName by removing trailing dot if present
:if ([:pick $recordName ([:len $recordName] - 1) [:len $recordName]] = ".") do={
    :set recordName [:pick $recordName 0 ([:len $recordName] - 1)]
}

# 1. Fetch current WAN IP address
:do {
    :local interfaceAddr [/ip address get [find where interface=$wanInterface] address]
    :set currentIp [:pick $interfaceAddr 0 [:find $interfaceAddr "/"]]
} on-error={
    :log error "Firestorm DynDNS: WAN interface $wanInterface not found."
}

# 2. Quick-Check: Record per DNS aufloesen und mit WAN-IP vergleichen.
#    Stimmt es ueberein, ist nichts zu tun -> Ende ohne API-Call.
:if ([:len $currentIp] > 0) do={
    :do {
        :set dnsIp [:tostr [:resolve $recordName server=$dnsServer]]
    } on-error={
        :log warning ("Firestorm DynDNS: Resolver " . $dnsServer . " failed for " . $recordName . ". Trying " . $dnsServer2 . "...")
        :do {
            :set dnsIp [:tostr [:resolve $recordName server=$dnsServer2]]
        } on-error={
            :log warning ("Firestorm DynDNS: Resolver " . $dnsServer2 . " also failed. Falling back to API check.")
        }
    }
}

:if ([:len $currentIp] > 0 && $dnsIp = $currentIp) do={
    :log info ("Firestorm DynDNS: DNS already up to date (" . $currentIp . "). Nothing to do.")
} else={

    # 3. Fetch current record IP via Firestorm API using :deserialize
    #    (old_data muss exakt dem aktuellen API-Wert entsprechen, sonst lehnt Firestorm ab)
    :if ([:len $currentIp] > 0) do={
        :local getUrl "https://api.firestorm.ch/dns/v1/zone/$zoneId/records"
        :local hUser ("X-Api-User: " . $apiUser)
        :local hKey ("X-Api-Key: " . $apiKey)
        :local getHeaders {$hUser; $hKey}
        :local fetchRes ""

        :do {
            :set fetchRes [/tool fetch url=$getUrl http-header-field=$getHeaders check-certificate=no as-value output=user]
        } on-error={
            :log error "Firestorm DynDNS: Failed to fetch DNS records from API."
        }

        :if ([:len $fetchRes] > 0 && ($fetchRes->"status") = "finished") do={
            :do {
                :local jsonData [:deserialize from=json value=($fetchRes->"data")]
                :foreach record in=($jsonData->"records") do={
                    :local recName ($record->"name")
                    :local recType ($record->"type")
                    :if ($recName = $recordName && $recType = "A") do={
                        :set oldIp ($record->"data")
                    }
                }
            } on-error={
                :log error "Firestorm DynDNS: Failed to parse JSON response with :deserialize."
            }

            :if ([:len $oldIp] = 0) do={
                :log error ("Firestorm DynDNS: Record " . $recordName . " not found in API response.")
            }
        }
    }

    # 4. Update DNS record if IP changed
    :if ([:len $oldIp] > 0) do={
        :if ($currentIp != $oldIp) do={
            :log info ("Firestorm DynDNS: IP change detected (" . $oldIp . " -> " . $currentIp . "). Updating DNS...")

            :local putUrl "https://api.firestorm.ch/dns/v1/zone/$zoneId/record"
            :local payload "{\"name\":\"$recordName\",\"type\":\"A\",\"old_data\":\"$oldIp\",\"data\":\"$currentIp\",\"ttl\":$ttl}"

            :local hUser ("X-Api-User: " . $apiUser)
            :local hKey ("X-Api-Key: " . $apiKey)
            :local hType "Content-Type: application/json"
            :local putHeaders {$hUser; $hKey; $hType}

            :do {
                /tool fetch url=$putUrl http-method=put http-header-field=$putHeaders http-data=$payload check-certificate=no as-value output=user
                :log info ("Firestorm DynDNS: Update successful for " . $recordName)
            } on-error={
                :log error "Firestorm DynDNS: Failed to update DNS record."
            }
        } else={
            :log info ("Firestorm DynDNS: API record already matches (" . $currentIp . "). DNS cache just lagging. No update required.")
        }
    } else={
        :log error "Firestorm DynDNS: Aborted update check because oldIp could not be determined."
    }
}
