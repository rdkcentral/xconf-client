#!/bin/sh
##########################################################################
# If not stated otherwise in this file or this component's Licenses.txt
# file the following copyright and licenses apply:
#
# Copyright 2017 RDK Management
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
# http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
##########################################################################

source /etc/utopia/service.d/log_capture_path.sh
source /fss/gw/etc/utopia/service.d/log_env_var.sh
source /lib/rdk/getpartnerid.sh
source /lib/rdk/getaccountid.sh
source /lib/rdk/t2Shared_api.sh
source /etc/waninfo.sh

if [ -f /etc/device.properties ]
then
    source /etc/device.properties
fi

if [ -f /etc/bundleUtils.sh ]
then
    source /etc/bundleUtils.sh
fi

XCONF_LOG_FILE_NAME=xconf.txt.0
XCONF_LOG_FILE_PATHNAME=${LOG_PATH}/${XCONF_LOG_FILE_NAME}
XCONF_LOG_FILE=${XCONF_LOG_FILE_PATHNAME}

CURL_PATH=/usr/bin
interface=$(getWanInterfaceName)
wan_interface=$(getWanMacInterfaceName)
BIN_PATH=/usr/bin
TMP_PATH=/tmp
REBOOT_WAIT="/tmp/.waitingreboot"
DOWNLOAD_INPROGRESS="/tmp/.downloadingfw"
deferReboot="/tmp/.deferringreboot"
NO_DOWNLOAD="/tmp/.downloadBreak"
ABORT_REBOOT="/tmp/AbortReboot"
abortReboot_count=0

FWDL_JSON=/tmp/response.txt
SIGN_FILE="/tmp/.signedRequest_$$_`date +'%s'`"

CODEBIG_BLOCK_TIME=1800
CODEBIG_BLOCK_FILENAME="/tmp/.lastcodebigfail_cdl"
FORCE_DIRECT_ONCE="/tmp/.forcedirectonce_cdl"

CONN_TRIES=3

#to support ocsp
EnableOCSPStapling="/tmp/.EnableOCSPStapling"
EnableOCSP="/tmp/.EnableOCSPCA"

#Rfc Agent files
RFC_JSON="/nvram/rfc.json"
PROCESSING_RFC="/tmp/.processingrfc"
PENDING_RFC_REBOOT="/tmp/.pendingrfcreboot"
APPLY_RFC="/tmp/applyRfc"

DAC15_DOMAIN="dac15cdlserver.ae.ccp.xcal.tv"

if [ -f $EnableOCSPStapling ] || [ -f $EnableOCSP ]; then
    CERT_STATUS="--cert-status"
fi

CONN_RETRIES=3
curr_conn_type=""
conn_str="Direct"
CodebigAvailable=0
UseCodebig=0

CURL_CMD_SSR=""
        
CRONTAB_DIR="/var/spool/cron/crontabs/"
CRON_FILE_BK="/tmp/cron_tab$$.txt"
LAST_HTTP_RESPONSE="/tmp/XconfSavedOutput"

#GLOBAL DECLARATIONS
image_upg_avl=0
reb_window=0

isPeriodicFWCheckEnabled=`syscfg get PeriodicFWCheck_Enable`

#See if maintenance window Supported
maintenance_window_mode=0
FW_START="/nvram/.FirmwareUpgradeStartTime"
FW_END="/nvram/.FirmwareUpgradeEndTime"

t_start_time=`cat $FW_START`
if [ "$t_start_time" != "" ]
then
    maintenance_window_mode=1
fi

echo_t()
{
	    echo "`date +"%y%m%d-%T.%6N"` $1"
}

# NOTE:: RDKB-20262 if rdkfwupgrader daemon is enabled, don't do anything in these scripts.
if [ "$isPeriodicFWCheckEnabled" == "true" ] ;then
        /etc/rdkfwupgrader_message.sh
        
        if [ $? -ne 0 ] ;then
            exit 1
        fi

fi

#Grab the model number
modelNum=`dmcli eRT getv Device.DeviceInfo.ModelName | awk '/value:/ {print "P"$5;}'`;
if [ "$modelNum" = "" ]
then
    echo "XCONF SCRIPT : modelNum not returnd from dmcli, revert to grabbing from /nvram/serialization.txt"
    modelNum=`grep MODEL /nvram/serialization.txt | sed 's/.*=/P/'`
fi
echo "XCONF SCRIPT : Model : $modelNum"


#
# release numbering system rules
#

# 5 part release numbering scheme where the five parts consisted of 
#+ "Major Rev"."Minor Rev"."Internal Rev". "Patch Level"."SPIN".

# 1.Major  Rev and Minor Rev will follow the matching RDKB version.
# 2.Any field which formerly contained  a zero (except for "Minor Rev") will be suppressed in the build number as well as the preceding "."
# 3.The "Spin" field will be  preceded by  "s"  for spin,  rather than a ".'  ie s4
# 4.The Spin field is always in the range of 1-x; Since it is  never 0, this field is always present.
# 5.The "Patch Level" field will be preceded by  "p" (lower case)  for patch rather than a "." . ie p2
# 6.The patch level field is in the range of 0-x.  If the patch level value is zero, the entire field will be suppressed including the leading "p". 
# 7."Internal Rev" can be in the range of 0-x, When the value of Internal Rev is 0, it will be suppressed, including the preceding "."
# 8.Initial State: We will be reverting the Internal Rev to Zero. This will allow us to suppress the field initially
# 9. The "Patch level" filed if present will always preceed "Spin" field.

# example build release numbers
# 1.22s55555                    spin_on_minor           3
# 1.22p4444s55555               spin_on_patch           1
# 1.22.333s55555                spin_on_internal        2
# 1.22.333p4444s55555           spin_on_patch           3
# 

# param1 : cur_rel_num param2 : upg_rel_num
# assumption : 
#       cur and upg firmware version are validated against release numbering system rules
#       no assumption is made about the length of the fields
# spin_on : 1 spin_on_patch 2 spin_on_internal 3 spin_on_minor


# Get currrent firmware in th eunit
getCurrentFw()
{
 currentfw=""
 # Check the location of version.txt file
 if [ -f "/fss/gw/version.txt" ]
 then
    currentfw=`grep image /fss/gw/version.txt | cut -f2 -d:`
 elif [ -f "/version.txt" ]
 then
    if [ "$currentfw" = "" ]
	then
        currentfw=`grep image /version.txt | cut -f2 -d:`
	fi
 fi
 echo $currentfw
}

getRequestType()
{
     request_type=2
     if [ "$1" == "ci.xconfds.ccp.xcal.tv" ]; then
            request_type=4
     fi
     return $request_type
}

checkFirmwareUpgCriteria()
{
    image_upg_avl=0;

    # Retrieve current firmware version
    currentVersion=`getCurrentFw`
    current_FW_Version=$currentVersion
    update_FW_Version=$firmwareVersion
    #Comcast signed firmware images are represented in lower case and vendor signed images are represented in upper case.
    #In order to avoid confusion in string comparison, converting both currentVersion and firmwareVersion to lower case.
    currentVersion=`echo $currentVersion | tr '[A-Z]' '[a-z]'`
    firmwareVersion=`echo $firmwareVersion | tr '[A-Z]' '[a-z]'`


    echo_t "XCONF SCRIPT : CurrentVersion : $currentVersion"
    echo_t "XCONF SCRIPT : UpgradeVersion : $firmwareVersion"

    echo_t "XCONF SCRIPT : CurrentVersion : $currentVersion" >> $XCONF_LOG_FILE
    echo_t "XCONF SCRIPT : UpgradeVersion : $firmwareVersion" >> $XCONF_LOG_FILE

    if [ "$currentVersion" != "" ] && [ "$firmwareVersion" != "" ];then
		if [ "$currentVersion" == "$firmwareVersion" ]; then
			echo_t "XCONF SCRIPT : Current image ("$currentVersion") and Requested image ("$firmwareVersion") are same. No upgrade/downgrade required"
			echo_t "XCONF SCRIPT : Current image ("$currentVersion") and Requested image ("$firmwareVersion") are same. No upgrade/downgrade required">> $XCONF_LOG_FILE
			image_upg_avl=0
                        
                        if [ "$isPeriodicFWCheckEnabled" == "true" ]; then
			   exit
			fi
		else
			echo_t "XCONF SCRIPT : Current image ("$currentVersion") and Requested image ("$firmwareVersion") are different. Processing Upgrade/Downgrade"
			echo_t "XCONF SCRIPT : Current image ("$currentVersion") and Requested image ("$firmwareVersion") are different. Processing Upgrade/Downgrade">> $XCONF_LOG_FILE
			image_upg_avl=1
		fi
	else
		echo_t "XCONF SCRIPT : Current image ("$currentVersion") Or Requested image ("$firmwareVersion") returned NULL. No Upgrade/Downgrade"
		echo_t "XCONF SCRIPT : Current image ("$currentVersion") Or Requested image ("$firmwareVersion") returned NULL. No Upgrade/Downgrade">> $XCONF_LOG_FILE
		image_upg_avl=0
                
                if [ "$isPeriodicFWCheckEnabled" == "true" ]; then
		   exit
		fi
	fi
}

IsCodebigBlocked()
{
    ret=0
    if [ -f $CODEBIG_BLOCK_FILENAME ]; then
        modtime=$(($(date +%s) - $(date +%s -r $CODEBIG_BLOCK_FILENAME)))
        if [ "$modtime" -le "$CODEBIG_BLOCK_TIME" ]; then
            echo "XCONF SCRIPT: Last Codebig failed blocking is still valid, preventing Codebig" >>  $DCM_LOG_FILE
            ret=1
        else
            echo "XCONF SCRIPT: Last Codebig failed blocking has expired, removing $CODEBIG_BLOCK_FILENAME, allowing Codebig" >> $DCM_LOG_FILE
            rm -f $CODEBIG_BLOCK_FILENAME
            ret=0
        fi
    fi
    return $ret
}

# Get the configuration of codebig settings
get_Codebigconfig()
{
   # If configparamgen not available, then only direct connection available and no fallback mechanism
   if [ -f $CONFIGPARAMGEN ]; then
      CodebigAvailable=1
   fi
   if [ "$CodebigAvailable" -eq "1" ]; then 
       CodeBigEnable=`dmcli eRT getv Device.DeviceInfo.X_RDKCENTRAL-COM_RFC.Feature.CodeBigFirst.Enable | grep true 2>/dev/null`
   fi
   if [ -f $FORCE_DIRECT_ONCE ]; then
      rm -f $FORCE_DIRECT_ONCE
      echo_t "XCONF SCRIPT : Last Codebig attempt failed, forcing direct once" >> $XCONF_LOG_FILE
   elif [ "$CodebigAvailable" -eq "1" ] && [ "x$CodeBigEnable" != "x" ] ; then 
      UseCodebig=1
      conn_str="Codebig" 
   fi

   if [ "$CodebigAvailable" -eq "1" ]; then
      echo_t "XCONF SCRIPT : Using $conn_str connection as the Primary"
      echo_t "XCONF SCRIPT : Using $conn_str connection as the Primary" >> $XCONF_LOG_FILE
   else
      echo_t "XCONF SCRIPT : Only $conn_str connection is available"
      echo_t "XCONF SCRIPT : Only $conn_str connection is available" >> $XCONF_LOG_FILE
   fi
}

# Get and set the codebig signed info
do_Codebig_signing()
{
     if [ "$1" = "Xconf" ]; then
            domain_name=`echo $xconf_url | cut -d / -f3`
            getRequestType $domain_name
            request_type=$?
            SIGN_CMD="configparamgen $request_type \"$JSONSTR\""
            eval $SIGN_CMD > $SIGN_FILE
            CB_SIGNED_REQUEST=`cat $SIGN_FILE`
            rm -f $SIGN_FILE
      else
            request_type=1
            domainName=`echo $imageHTTPURL | awk -F/ '{print $3}'`
            if [ "$domainName" == "$DAC15_DOMAIN" ]; then
                request_type=14
            fi
            SIGN_CMD="configparamgen $request_type \"$imageHTTPURL\""
            echo $SIGN_CMD >>$XCONF_LOG_FILE
            echo -e "\n"
            eval $SIGN_CMD > $SIGN_FILE
            cbSignedimageHTTPURL=`cat $SIGN_FILE`
            rm -f $SIGN_FILE
#            echo $cbSignedimageHTTPURL >>$XCONF_LOG_FILE
            cbSignedimageHTTPURL=`echo $cbSignedimageHTTPURL | sed 's|stb_cdl%2F|stb_cdl/|g'`
            serverUrl=`echo $cbSignedimageHTTPURL | sed -e "s|[?&]oauth_consumer_key.*||g"`
            authorizationHeader=`echo $cbSignedimageHTTPURL | sed -e "s|&|\", |g" -e "s|=|=\"|g" -e "s|.*oauth_consumer_key|oauth_consumer_key|g"`
            authorizationHeader="Authorization: OAuth realm=\"\", $authorizationHeader\""
            CURL_CMD_SSR="curl $CERT_STATUS --connect-timeout 30 --tlsv1.2 --interface $interface -H '$authorizationHeader' $addr_type -w '%{http_code}\n' -fgLo $TMP_PATH/$firmwareFilename '$serverUrl'"
      fi
}

# Direct connection Download function
useDirectRequest()
{
            curr_conn_type="direct"
            echo_t "Trying Direct Communication"
            echo_t "Trying Direct Communication" >> $XCONF_LOG_FILE
            CURL_CMD="$CURL_PATH/curl --interface $interface $addr_type -w '%{http_code}\n' --tlsv1.2 -d \"$JSONSTR\" -o \"$FWDL_JSON\" \"$xconf_url\" $CERT_STATUS --connect-timeout 30 -m 30"
            echo_t "CURL_CMD:$CURL_CMD"
            echo_t "CURL_CMD:$CURL_CMD" >> $XCONF_LOG_FILE
            HTTP_CODE=`result= eval $CURL_CMD`
            ret=$?
            HTTP_RESPONSE_CODE=$(echo "$HTTP_CODE" | awk -F\" '{print $1}' )
            echo_t "Direct Communication - ret:$ret, http_code:$HTTP_RESPONSE_CODE" | tee -a $XCONF_LOG_FILE ${LOG_PATH}/TlsVerify.txt
            # log security failure
            case $ret in
              35|51|53|54|58|59|60|64|66|77|80|82|83|90|91)
                echo_t "Direct Communication Failure - ret:$ret, http_code:$HTTP_RESPONSE_CODE" >> $XCONF_LOG_FILE
                ;;
            esac
            [ "x$HTTP_RESPONSE_CODE" != "x" ] || HTTP_RESPONSE_CODE=0
}

# Codebig connection Download function
useCodebigRequest()
{
            curr_conn_type="codebig"
            # Do not try Codebig if CodebigAvailable != 1 (configparamgen not there)
            if [ "$CodebigAvailable" -eq "0" ] ; then
                  echo_t "XCONF SCRIPT: Only direct connection Available" >> $XCONF_LOG_FILE
                  return 1
            fi

            IsCodebigBlocked
            if [ "$?" -eq "1" ]; then
                return 1
            fi
            do_Codebig_signing "Xconf"
            CURL_CMD="$CURL_PATH/curl --interface $interface $addr_type -w '%{http_code}\n' --tlsv1.2 -o \"$FWDL_JSON\" \"$CB_SIGNED_REQUEST\" $CERT_STATUS --connect-timeout 30 -m 30"
            echo_t "Trying Codebig Communication at `echo "$CURL_CMD" | sed -ne 's#.*\(https:.*\)?.*#\1#p'`"
            echo_t "Trying Codebig Communication at `echo "$CURL_CMD" | sed -ne 's#.*\(https:.*\)?.*#\1#p'`" >> $XCONF_LOG_FILE
            echo_t "CURL_CMD: `echo "$CURL_CMD" | sed -ne 's#oauth_consumer_key=.*oauth_signature.* --#<hidden> --#p'`" 
            echo_t "CURL_CMD: `echo "$CURL_CMD" | sed -ne 's#oauth_consumer_key=.*oauth_signature.* --#<hidden> --#p'`"  >> $XCONF_LOG_FILE
            HTTP_CODE=`result= eval $CURL_CMD`
            ret=$?
            HTTP_RESPONSE_CODE=$(echo "$HTTP_CODE" | awk -F\" '{print $1}' )
            echo_t "Codebig Communication - ret:$ret, http_code:$HTTP_RESPONSE_CODE" | tee -a $XCONF_LOG_FILE ${LOG_PATH}/TlsVerify.txt
            # log security failure
            case $ret in
              35|51|53|54|58|59|60|64|66|77|80|82|83|90|91)
                echo_t "Codebig Communication Failure - ret:$ret, http_code:$HTTP_RESPONSE_CODE" >> $XCONF_LOG_FILE
                ;;
            esac
}

# Check if a new image is available on the XCONF server
getFirmwareUpgDetail()
{
    # The retry count and flag are used to resend a 
    # query to the XCONF server if issues with the 
    # respose or the URL received
    xconf_retry_count=0
    retry_flag=1
    directconn_count=1
    isIPv6=`ifconfig $interface | grep inet6 | grep -i 'Global'`

    # Set the XCONF server url read from /tmp/Xconf 
    # Determine the env from $type

    #s16 : env=`cat /tmp/Xconf | cut -d "=" -f1`
    env=$type

    # If an /tmp/Xconf file was not created, use the default values
    if [ ! -f /tmp/Xconf ]; then
        echo_t "XCONF SCRIPT : ERROR : /tmp/Xconf file not found! Using defaults"
        echo_t "XCONF SCRIPT : ERROR : /tmp/Xconf file not found! Using defaults" >> $XCONF_LOG_FILE
        env="PROD"
        xconf_url="https://xconf.xcal.tv/xconf/swu/stb/"
    else
        xconf_url=`cut -d "=" -f2 /tmp/Xconf`
    fi

    # if xconf_url uses http, then log it
    case $(echo "$xconf_url" | cut -d ":" -f1 | tr '[:upper:]' '[:lower:]') in
        "https")
            #echo_t "XCONF SCRIPT : firmware download config using HTTPS to $xconf_url" >> $XCONF_LOG_FILE
            ;;
        "http")
            echo_t "XCONF SCRIPT : firmware download config using HTTP to $xconf_url" >> $XCONF_LOG_FILE
            ;;
        *)
            echo_t "XCONF SCRIPT : ERROR : firmware download config using invalid URL to '$xconf_url'" >> $XCONF_LOG_FILE
            ;;
    esac

    echo_t "XCONF SCRIPT : env is $env"
    echo_t "XCONF SCRIPT : xconf url  is $xconf_url"

    # If interface doesnt have ipv6 address then we will force the curl to go with ipv4.
    # Otherwise we will not specify the ip address family in curl options
    if [ "$isIPv6" != "" ]; then
        addr_type=""
    else
        addr_type="-4"
    fi
    uptime=`cat /proc/uptime | awk '{ print $1 }' | cut -d"." -f1`
    echo_t "XCONF SCRIPT : Searching for connection type:$uptime" >> $XCONF_LOG_FILE
    t2ValNotify "xconf_reaching_ssr" "$uptime"
    get_Codebigconfig

    # Check with the XCONF server if an update is available 
    while [ $xconf_retry_count -lt $CONN_TRIES ] && [ $retry_flag -eq 1 ]
    do

        echo_t "**RETRY is $((xconf_retry_count + 1)) and RETRY_FLAG is $retry_flag**" >> $XCONF_LOG_FILE
        
        # White list the Xconf server url
        #echo "XCONF SCRIPT : Whitelisting Xconf Server url : $xconf_url"
        #echo "XCONF SCRIPT : Whitelisting Xconf Server url : $xconf_url" >> $XCONF_LOG_FILE
        #/etc/whitelist.sh "$xconf_url"
        
        # Perform cleanup by deleting any previous responses
        rm -f $FWDL_JSON /tmp/XconfOutput.txt
        firmwareDownloadProtocol=""
        firmwareFilename=""
        firmwareLocation=""
        firmwareVersion=""
        rebootImmediately=""
        ipv6FirmwareLocation=""
        upgradeDelay=""
        delayDownload=""
        factoryResetImmediately=""
       
        currentVersion=`getCurrentFw`
		
        MAC=`ifconfig  | grep $wan_interface |  grep -v $wan_interface:0 | tr -s ' ' | cut -d ' ' -f5`
        serialNumber=`grep SERIAL_NUMBER /nvram/serialization.txt | cut -f 2 -d "="`
        date=`date`
        modelName=`dmcli eRT getv Device.DeviceInfo.ModelName | awk '/value:/ {print $5;}'`;
        if [ "$modelName" = "" ]
        then
            echo_t "XCONF SCRIPT : modelNum not returnd from dmcli, revert to grabbing from /nvram/serialization.txt"
            modelName=`grep MODEL /nvram/serialization.txt | sed 's/.*=//'`
        fi
        # Add leading P to model since XConf SW upgrade server expects it (XF3-3547)
        modelName=$(echo $modelName | sed 's/^/P/')

        echo_t "XCONF SCRIPT : CURRENT VERSION : $currentVersion" 
        echo_t "XCONF SCRIPT : CURRENT MAC  : $MAC"
        echo_t "XCONF SCRIPT : CURRENT SERIAL NUMBER : $serialNumber" 
        echo_t "XCONF SCRIPT : CURRENT DATE : $date"  
        echo_t "XCONF SCRIPT : MODEL : $modelName"

        # Query the  XCONF Server, using TLS 1.2
        echo_t "Attempting TLS1.2 connection to $xconf_url " >> $XCONF_LOG_FILE
        partnerId=$(getPartnerId)
        accountId=$(getAccountId)
        unitActivationStatus=`syscfg get unit_activated`

        if [ -z "$unitActivationStatus" ] || [ $unitActivationStatus -eq 0 ]; then
            activationInProgress="true"
        else
            activationInProgress="false"
        fi

        instBundles=$(getInstalledBundleList)

        JSONSTR='eStbMac='${MAC}'&firmwareVersion='${currentVersion}'&serial='${serialNumber}'&env='${env}'&model='${modelName}'&partnerId='${partnerId}'&activationInProgress='${activationInProgress}'&accountId='${accountId}'&localtime='${date}'&dlCertBundle='${instBundles}'&timezone=EST05&capabilities=rebootDecoupled&capabilities=RCDL&capabilities=supportsFullHttpUrl'

        if [ "$UseCodebig" = "1" ]; then
           useCodebigRequest
        else
           useDirectRequest
        fi
        [ "x$HTTP_RESPONSE_CODE" != "x" ] || HTTP_RESPONSE_CODE=0
        echo_t "XCONF SCRIPT : HTTP RESPONSE CODE is $HTTP_RESPONSE_CODE"
        echo_t "XCONF SCRIPT : HTTP RESPONSE CODE is $HTTP_RESPONSE_CODE" >> $XCONF_LOG_FILE

        if [ "x$HTTP_RESPONSE_CODE" = "x200" ];then
            # Print the response
            cat $FWDL_JSON
            echo
            cat $FWDL_JSON >> $XCONF_LOG_FILE
            echo >> $XCONF_LOG_FILE

            retry_flag=0
			
	    OUTPUT="/tmp/XconfOutput.txt" 
            cat $FWDL_JSON | tr -d '\n' | sed 's/[{}]//g' | awk  '{n=split($0,a,","); for (i=1; i<=n; i++) print a[i]}' | sed 's/\"\:\"/\|/g' | sed -r 's/\"\:(true)($)/\|true/gI' | sed -r 's/\"\:(false)($)/\|false/gI' | sed -r 's/\"\:(null)($)/\|\1/gI' | sed -r 's/\"\:(-?[0-9]+)($)/\|\1/g' | sed 's/[\,]/ /g' | sed 's/\"//g' > $OUTPUT
            
	    firmwareDownloadProtocol=`grep firmwareDownloadProtocol $OUTPUT  | cut -d \| -f2`
            echo_t "XCONF SCRIPT : firmwareDownloadProtocol [$firmwareDownloadProtocol]"
            echo_t "XCONF SCRIPT : firmwareDownloadProtocol [$firmwareDownloadProtocol]" >> $XCONF_LOG_FILE

            if [ "$firmwareDownloadProtocol" == "http" ];then
                echo_t "XCONF SCRIPT : Download image from HTTP server" >> $XCONF_LOG_FILE
                firmwareLocation=`grep firmwareLocation $OUTPUT | cut -d \| -f2 | tr -d ' '`
            else
                echo_t "XCONF SCRIPT : Download from $firmwareDownloadProtocol server not supported, check XCONF server configurations"
                echo_t "XCONF SCRIPT : Download from $firmwareDownloadProtocol server not supported, check XCONF server configurations" >> $XCONF_LOG_FILE
                
                retry_flag=1
                image_upg_avl=0

                if [ $xconf_retry_count -lt $((CONN_TRIES - 1)) ]; then
                    if [ "$curr_conn_type" = "direct" ]; then
                        sleep_time=120
                    elif [ "$xconf_retry_count" -eq "0" ]; then
                        sleep_time=10
                    else
                        sleep_time=30
                    fi
                    echo_t "XCONF SCRIPT : Retrying query in $sleep_time seconds" >> $XCONF_LOG_FILE
                       sleep $sleep_time
                fi
                #Increment the retry count
                xconf_retry_count=$((xconf_retry_count+1))
                continue
            fi

            firmwareFilename=`grep firmwareFilename $OUTPUT | cut -d \| -f2`
    	    firmwareVersion=`grep firmwareVersion $OUTPUT | cut -d \| -f2 | sed 's/-signed.*//'`
	    ipv6FirmwareLocation=`grep ipv6FirmwareLocation  $OUTPUT | cut -d \| -f2 | tr -d ' '`
	    upgradeDelay=`grep upgradeDelay $OUTPUT | cut -d \| -f2`
	    delayDownload=`grep delayDownload $OUTPUT | cut -d \| -f2`
            rebootImmediately=`grep rebootImmediately $OUTPUT | cut -d \| -f2`
            factoryResetImmediately=`grep factoryResetImmediately $OUTPUT | cut -d \| -f2`   
            dlCertBundle=$($JSONQUERY -f $FWDL_JSON -p dlCertBundle)
                                    
	
            if [ "X"$firmwareLocation = "X" ];then
                echo_t "XCONF SCRIPT : No URL received in $FWDL_JSON"
                echo_t "XCONF SCRIPT : No URL received in $FWDL_JSON" >> $XCONF_LOG_FILE
                retry_flag=1
                image_upg_avl=0

                if [ $xconf_retry_count -lt $((CONN_TRIES - 1)) ]; then
                    if [ "$xconf_retry_count" -eq "0" ]; then
                        sleep_time=10
                    else
                        sleep_time=30
                    fi
                    echo_t "XCONF SCRIPT : Retrying query in $sleep_time seconds" >> $XCONF_LOG_FILE
                    sleep $sleep_time
                fi
                #Increment the retry count
                xconf_retry_count=$((xconf_retry_count+1))

            else
                # Will only entry here is last connection was success with 200 & http. So use the last succesful conn type.
                if [ "$curr_conn_type" = "direct" ]; then 
                    echo_t "XCONF SCRIPT : SSR download is set to : DIRECT" 
                    echo_t "XCONF SCRIPT : SSR download is set to : DIRECT" >> $XCONF_LOG_FILE
                    echo_t "XCONF SCRIPT : Protocol :"$firmwareDownloadProtocol
                    echo_t "XCONF SCRIPT : Filename :"$firmwareFilename
                    echo_t "XCONF SCRIPT : Location :"$firmwareLocation
                    echo_t "XCONF SCRIPT : Version  :"$firmwareVersion
                    echo_t "XCONF SCRIPT : Reboot   :"$rebootImmediately
                    echo_t "XCONF SCRIPT : factoryResetImmediately :"$factoryResetImmediately
                    echo_t "XCONF SCRIPT : dlCertBundle :"$dlCertBundle
                    dmcli eRT setv Device.DeviceInfo.X_RDKCENTRAL-COM_FirmwareDownloadURL string "$firmwareLocation"
                else
                    echo_t "XCONF SCRIPT : SSR download is set to : CODEBIG" 
                    echo_t "XCONF SCRIPT : SSR download is set to : CODEBIG" >> $XCONF_LOG_FILE
                    serverUrl=""
                    authorizationHeader=""
                    imageHTTPURL="$firmwareLocation/$firmwareFilename"
                    domainName=`echo $imageHTTPURL | awk -F/ '{print $3}'`
                    imageHTTPURL=`echo $imageHTTPURL | sed -e "s|.*$domainName||g"`
                    do_Codebig_signing "SSR" 
                    # firmwareLocation=`echo "$serverUrl" | sed -ne 's/\/'"$firmwareFilename.*"'//p'`
                    echo_t "XCONF SCRIPT : Protocol :"$firmwareDownloadProtocol 
                    echo_t "XCONF SCRIPT : Filename :"$firmwareFilename 
                    echo_t "XCONF SCRIPT : Location :"`echo "$serverUrl" | sed -ne 's/\/'"$firmwareFilename.*"'//p'` 
                    echo_t "XCONF SCRIPT : Version  :"$firmwareVersion
                    echo_t "XCONF SCRIPT : Reboot   :"$rebootImmediately
                    echo_t "XCONF SCRIPT : factoryResetImmediately :"$factoryResetImmediately
                    echo_t "XCONF SCRIPT : dlCertBundle :"$dlCertBundle
                    dmcli eRT setv Device.DeviceInfo.X_RDKCENTRAL-COM_FirmwareDownloadURL string "`echo "$serverUrl" | sed -ne 's/\/'"$firmwareFilename.*"'//p'`"
                fi

                #RDKB-35095 AC#3
                if [ "$firmwareFilename" = "" ];then
                    dmcli eRT setv Device.DeviceInfo.X_RDKCENTRAL-COM_FirmwareToDownload string "$currentVersion"
                else
                    dmcli eRT setv Device.DeviceInfo.X_RDKCENTRAL-COM_FirmwareToDownload string "$firmwareFilename"
                fi

                if [ -n "$delayDownload" ]; then
                    echo_t "XCONF SCRIPT : Device configured with download delay of $delayDownload minutes"
                    echo_t "XCONF SCRIPT : Device configured with download delay of $delayDownload minutes" >> $XCONF_LOG_FILE
                fi

                if [ -z "$delayDownload" ] || [ "$rebootImmediately" = "true" ] || [ "$factoryResetImmediately" = "true" ] || [ $delayDownload -lt 0 ];then
                    delayDownload=0
                    echo_t "XCONF SCRIPT : Resetting the download delay to 0 minutes" >> $XCONF_LOG_FILE
                fi

                # Check if xconf returned any bundles to update
                # If so, trigger /etc/rdm/rdmBundleMgr.sh to process it
                if [ -n "$dlCertBundle" ]; then
                    echo_t "XCONF SCRIPT : Calling /etc/rdm/rdmBundleMgr.sh to process bundle update" >> $XCONF_LOG_FILE
                    (sh /etc/rdm/rdmBundleMgr.sh "$dlCertBundle" "$firmwareLocation" >> ${LOG_PATH}/rdm_status.log 2>&1) &
                    echo_t "XCONF SCRIPT : /etc/rdm/rdmBundleMgr.sh started in background" >> $XCONF_LOG_FILE
                fi

           	# Check if a newer version was returned in the response
                # If image_upg_avl = 0, retry reconnecting with XCONf in next window
                # If image_upg_avl = 1, download new firmware 
                echo "$firmwareLocation" > /tmp/.xconfssrdownloadurl
                checkFirmwareUpgCriteria

                if [ $image_upg_avl -eq 1 ] && [ $delayDownload -ne 0 ] && [ "$triggeredFrom" != "delayedDownload" ];
                then
                    cp $OUTPUT $LAST_HTTP_RESPONSE
                    echo "curr_conn_type|$curr_conn_type" >> $LAST_HTTP_RESPONSE

                    now=$(date +"%T")
                    SchedAtHr=$(echo $now | cut -d':' -f1)
                    SchedAtMin=$(echo $now | cut -d':' -f2)
                    Sec=$(echo $now | cut -d':' -f3)

                    if [ $Sec -gt 29 ]; then
                        SchedAtMin=`expr $SchedAtMin + 1`
                    fi

                    SchedAtMin=`expr $SchedAtMin + $delayDownload`
                    while [ $SchedAtMin -gt 59 ]
                    do
                        SchedAtMin=`expr $SchedAtMin - 60`
                        SchedAtHr=`expr $SchedAtHr + 1`
                        if [ $SchedAtHr -gt 23 ]; then
                            SchedAtHr=0
                        fi
                    done

                    echo_t "XCONF SCRIPT : current Time: $now, download scheduled at $SchedAtHr:$SchedAtMin" >> $XCONF_LOG_FILE

                    if [ "$isPeriodicFWCheckEnabled" == "true" ]; then
                        crontab -l -c $CRONTAB_DIR > $CRON_FILE_BK
                        SCRIPT_NAME=${0##*/}
                        sed -i "/[A-Za-z0-9]*$SCRIPT_NAME 5 */d" $CRON_FILE_BK
                        echo "$SchedAtMin $SchedAtHr * * * /etc/$SCRIPT_NAME 5" >> $CRON_FILE_BK
                        crontab $CRON_FILE_BK -c $CRONTAB_DIR
                        rm -rf $CRON_FILE_BK

                        exit
                    else
                        delayDownloadSec=$((delayDownload*60))
                        sleep $delayDownloadSec
                    fi
                fi
            fi
		

        # If a response code of 404 was received, exit
            elif [ "x$HTTP_RESPONSE_CODE" = "x404" ]; then
                retry_flag=0
                image_upg_avl=0
                echo_t "XCONF SCRIPT : Response code received is 404" >> $XCONF_LOG_FILE
                
                if [ "$isPeriodicFWCheckEnabled" == "true" ]; then
		   exit
		fi
        # If a response code of 0 was received, the server is unreachable
        # Try reconnecting
        else

            retry_flag=1
            image_upg_avl=0

            if [ $xconf_retry_count -lt $((CONN_TRIES - 1)) ]; then
                if [ "$curr_conn_type" = "direct" ]; then
                    sleep_time=120
                elif [ "$xconf_retry_count" -eq "0" ]; then
                    sleep_time=10
                else
                    sleep_time=30
                fi
                echo_t "XCONF SCRIPT : Retrying query in $sleep_time seconds" >> $XCONF_LOG_FILE
                   sleep $sleep_time
            fi
            #Increment the retry count
            xconf_retry_count=$((xconf_retry_count+1))
        fi
        interface=$(getWanInterfaceName)

    done

    # If try for CONN_TRIES times done and image is not available, then exit
    # Cron scheduled job will be triggered later
    if [ $xconf_retry_count -ge $CONN_TRIES ] && [ $image_upg_avl -eq 0 ]
    then
        if [ "$curr_conn_type" != "direct" ]; then
            [ -f $CODEBIG_BLOCK_FILENAME ] || touch $CODEBIG_BLOCK_FILENAME
            touch $FORCE_DIRECT_ONCE
        fi
        echo_t "XCONF SCRIPT : Retry limit to connect with XCONF server reached, so exit" 
        if [ "$isPeriodicFWCheckEnabled" == "true" ]; then
	   exit
	fi
    fi
}

#Fetch firmware name and location from last saved response.
fetchFirmwareDetail()
{
    #Firmware download delay timer expired. Remove it from cron.
    SCRIPT_NAME=${0##*/}
    crontab -l -c $CRONTAB_DIR > $CRON_FILE_BK
    sed -i "/[A-Za-z0-9]*$SCRIPT_NAME 5 */d" $CRON_FILE_BK
    crontab $CRON_FILE_BK -c $CRONTAB_DIR
    rm -rf $CRON_FILE_BK

    if [ ! -e $LAST_HTTP_RESPONSE ]; then
        echo_t "XCONF SCRIPT : Last saved file not available" >> $XCONF_LOG_FILE
        return
    fi

    echo_t "XCONF SCRIPT : Fetching firmware details from last saved response" >> $XCONF_LOG_FILE

    firmwareDownloadProtocol=`grep firmwareDownloadProtocol $LAST_HTTP_RESPONSE  | cut -d \| -f2`
    firmwareLocation=`grep firmwareLocation $LAST_HTTP_RESPONSE | cut -d \| -f2 | tr -d ' '`
    firmwareFilename=`grep firmwareFilename $LAST_HTTP_RESPONSE | cut -d \| -f2`

    if [ -z "$firmwareLocation" ] || [ -z "$firmwareFilename" ]; then
        echo_t "XCONF SCRIPT : Fetch firmware upgrade details from Xconf" >> $XCONF_LOG_FILE
        return
    fi

    firmwareVersion=`grep firmwareVersion $LAST_HTTP_RESPONSE | cut -d \| -f2`
    ipv6FirmwareLocation=`grep ipv6FirmwareLocation $LAST_HTTP_RESPONSE | cut -d \| -f2 | tr -d ' '`
    delayDownload=`grep delayDownload $LAST_HTTP_RESPONSE | cut -d \| -f2`
    rebootImmediately=`grep rebootImmediately $LAST_HTTP_RESPONSE | cut -d \| -f2`
    curr_conn_type=`grep curr_conn_type $LAST_HTTP_RESPONSE | cut -d \| -f2`
    factoryResetImmediately=`grep factoryResetImmediately $LAST_HTTP_RESPONSE | cut -d \| -f2`

    image_upg_avl=1;

    if [ "$curr_conn_type" != "direct" ]; then
        serverUrl=""
        authorizationHeader=""
        imageHTTPURL="$firmwareLocation/$firmwareFilename"
        domainName=`echo $imageHTTPURL | awk -F/ '{print $3}'`
        imageHTTPURL=`echo $imageHTTPURL | sed -e "s|.*$domainName||g"`
        do_Codebig_signing "SSR"
    fi
}

calcRandTime()
{
    rand_hr=0
    rand_min=0
    rand_sec=0

    # Calculate random min
    rand_min=`awk -v min=0 -v max=59 -v seed=$RANDOM 'BEGIN{print int(((min+seed)/32768)*(max-min+1))}'`

    # Calculate random second
    rand_sec=`awk -v min=0 -v max=59 -v seed=$RANDOM 'BEGIN{print int(((min+seed)/32768)*(max-min+1))}'`

    #
    # Generate time to check for update
    #
    if [ $1 -eq '1' ]; then
        
        echo_t "XCONF SCRIPT : Check Update time being calculated within 24 hrs." 
        echo_t "XCONF SCRIPT : Check Update time being calculated within 24 hrs." >> $XCONF_LOG_FILE

        # Calculate random hour
        # The max random time can be 23:59:59
        rand_hr=`awk -v min=0 -v max=23 -v seed=$RANDOM 'BEGIN{print int(((min+seed)/32768)*(max-min+1))}'`

        echo_t "XCONF SCRIPT : Time Generated : $rand_hr hr $rand_min min $rand_sec sec"
        min_to_sleep=$(($rand_hr*60 + $rand_min))
        sec_to_sleep=$(($min_to_sleep*60 + $rand_sec))

        printf "XCONF SCRIPT : Checking update with XCONF server at \t";
        #date -u "$min_to_sleep minutes" +'%H:%M:%S'
	date -d "@$(( `date +%s`+$sec_to_sleep ))" +'%H:%M:%S'

        date_upgch_part="$(( `date +%s`+$sec_to_sleep ))"
        date_upgch_final=`date -d "@$date_upgch_part"`
	
	echo_t "XCONF SCRIPT : Checking update on $date_upgch_final"
	echo_t "XCONF SCRIPT : Checking update on $date_upgch_final" >> $XCONF_LOG_FILE

    fi

    #
    # Generate time to downlaod HTTP image
    # device reboot time 
    #
    if [ $2 -eq '1' ]; then
       
        if [ "$3" = "r" ]; then
            echo "XCONF SCRIPT : Device reboot time being calculated in maintenance window"
            echo "XCONF SCRIPT : Device reboot time being calculated in maintenance window" >> $XCONF_LOG_FILE
        fi 
                 
        # Calculate random hour
        # The max time random time can be 4:59:59
        #rand_hr=`awk -v min=0 -v max=3 -v seed="$(date +%h)" 'BEGIN{print int(min+$RANDOM*(max-min+1))}'`
        rand_hr=`awk -v min=0 -v max=3 -v seed=$RANDOM 'BEGIN{print int(((min+seed)/32768)*(max-min+1))}'`

        echo "XCONF SCRIPT : Time Generated : $rand_hr hr $rand_min min $rand_sec sec"

        if [ "$UTC_ENABLE" == "true" ]
        then
           cur_hr=`LTime H | sed 's/^0*//'`
           cur_min=`LTime M | sed 's/^0*//'`
           cur_sec=`date +"%S" | sed 's/^0*//'`
        else
           cur_hr=`date +"%H" | sed 's/^0*//'`
           cur_min=`date +"%M" | sed 's/^0*//'`
           cur_sec=`date +"%S" | sed 's/^0*//'`
        fi

        # Time to maintenance window
        if [ $cur_hr -eq 0 ];then
            start_hr=0
        else
            start_hr=`expr 23 - ${cur_hr} + 1`
        fi

        start_min=`expr 59 - ${cur_min}`
        start_sec=`expr 59 - ${cur_sec}`

        # TIME TO START OF MAINTENANCE WINDOW
        echo "XCONF SCRIPT : Time to 1:00 AM : $start_hr hours, $start_min minutes and $start_sec seconds "
        min_wait=$((start_hr*60 + $start_min))
        # date -d "$time today + $min_wait minutes + $start_sec seconds" +'%H:%M:%S'
        date  -d "@$(( `date +%s`+$(($min_wait*60 + $start_sec)) ))"

        # TIME TO START OF HTTP_DL/REBOOT_DEV

        total_hr=$(($start_hr + $rand_hr))
        total_min=$(($start_min + $rand_min))
        total_sec=$(($start_sec + $rand_sec))

        min_to_sleep=$(($total_hr*60 + $total_min)) 
        sec_to_sleep=$(($min_to_sleep*60 + $total_sec))

        printf "XCONF SCRIPT : Action will be performed on ";
        # date -d "$sec_to_sleep seconds" +'%H:%M:%S'
        date -d "@$(( `date +%s`+$sec_to_sleep ))"

        date_part="$(( `date +%s`+$sec_to_sleep ))"
        date_final=`date -d "@$date_part" +'%H:%M:%S'`

        echo "Action on $date_final" >> $XCONF_LOG_FILE
        touch $REBOOT_WAIT

    fi

    echo "XCONF SCRIPT : SLEEPING FOR $min_to_sleep minutes or $sec_to_sleep seconds"
    echo "XCONF SCRIPT : SLEEPING FOR $min_to_sleep minutes or $sec_to_sleep seconds" >> $XCONF_LOG_FILE
    
    #echo "XCONF SCRIPT : SPIN 17 : sleeping for 30 sec, *******TEST BUILD***********"
    #sec_to_sleep=30

    sleep $sec_to_sleep
    echo "XCONF script : got up after $sec_to_sleep seconds"
}

#Fetch firmware name and location from last saved response.
fetchFirmwareDetail()
{
    #Firmware download delay timer expired. Remove it from cron.
    SCRIPT_NAME=${0##*/}
    crontab -l -c $CRONTAB_DIR > $CRON_FILE_BK
    sed -i "/[A-Za-z0-9]*$SCRIPT_NAME 5 */d" $CRON_FILE_BK
    crontab $CRON_FILE_BK -c $CRONTAB_DIR
    rm -rf $CRON_FILE_BK

    if [ ! -e $LAST_HTTP_RESPONSE ]; then
        echo_t "XCONF SCRIPT : Last saved file not available" >> $XCONF_LOG_FILE
        return
    fi

    echo_t "XCONF SCRIPT : Fetching firmware details from last saved response" >> $XCONF_LOG_FILE

    firmwareDownloadProtocol=`grep firmwareDownloadProtocol $LAST_HTTP_RESPONSE  | cut -d \| -f2`
    firmwareLocation=`grep firmwareLocation $LAST_HTTP_RESPONSE | cut -d \| -f2 | tr -d ' '`
    firmwareFilename=`grep firmwareFilename $LAST_HTTP_RESPONSE | cut -d \| -f2`

    if [ -z "$firmwareLocation" ] || [ -z "$firmwareFilename" ]; then
        echo_t "XCONF SCRIPT : Fetch firmware upgrade details from Xconf" >> $XCONF_LOG_FILE
        return
    fi

    firmwareVersion=`grep firmwareVersion $LAST_HTTP_RESPONSE | cut -d \| -f2`
    ipv6FirmwareLocation=`grep ipv6FirmwareLocation $LAST_HTTP_RESPONSE | cut -d \| -f2 | tr -d ' '`
    delayDownload=`grep delayDownload $LAST_HTTP_RESPONSE | cut -d \| -f2`
    rebootImmediately=`grep rebootImmediately $LAST_HTTP_RESPONSE | cut -d \| -f2`
    curr_conn_type=`grep curr_conn_type $LAST_HTTP_RESPONSE | cut -d \| -f2`
    factoryResetImmediately=`grep factoryResetImmediately $LAST_HTTP_RESPONSE | cut -d \| -f2`

    image_upg_avl=1;

    if [ "$curr_conn_type" != "direct" ]; then
        serverUrl=""
        authorizationHeader=""
        imageHTTPURL="$firmwareLocation/$firmwareFilename"
        domainName=`echo $imageHTTPURL | awk -F/ '{print $3}'`
        imageHTTPURL=`echo $imageHTTPURL | sed -e "s|.*$domainName||g"`
        do_Codebig_signing "SSR"
    fi
}

calcRandTimeBCI()
{
    rand_hr=0
    rand_min=0
    rand_sec=0

    # Calculate random min
    rand_min=`awk -v min=0 -v max=59 -v seed="$(date +%N)" 'BEGIN{srand(seed);print int(min+rand()*(max-min+1))}'`

    # Calculate random second
    rand_sec=`awk -v min=0 -v max=59 -v seed="$(date +%N)" 'BEGIN{srand(seed);print int(min+rand()*(max-min+1))}'`

    # Extract maintenance window start and end time
    if [ -f "$FW_START" ] && [ -f "$FW_END" ]
    then
      start_time=`cat $FW_START`
      end_time=`cat $FW_END`
    fi

    if [ "$start_time" = "$end_time" ]
    then
        echo_t "XCONF SCRIPT : Start time can not be equal to end time"
        echo_t "XCONF SCRIPT : Resetting values to default"
        echo_t "XCONF SCRIPT : Start time can not be equal to end time" >> $XCONF_LOG_FILE
	t2CountNotify "Test_StartEndEqual"
        echo_t "XCONF SCRIPT : Resetting values to default" >> $XCONF_LOG_FILE
        start_time=0
        end_time=10800
        echo "$start_time" > $FW_START
        echo "$end_time" > $FW_END
    fi

    echo_t "XCONF SCRIPT : Firmware upgrade start time : $start_time"
    echo_t "XCONF SCRIPT : Firmware upgrade end time : $end_time"
    echo_t "XCONF SCRIPT : Firmware upgrade start time : $start_time" >> $XCONF_LOG_FILE
    echo_t "XCONF SCRIPT : Firmware upgrade end time : $end_time" >> $XCONF_LOG_FILE

    #
    # Generate time to check for update
    #
    if [ $1 -eq '1' ]; then
        
        echo_t "XCONF SCRIPT : Check Update time being calculated within 24 hrs."
        echo_t "XCONF SCRIPT : Check Update time being calculated within 24 hrs." >> $XCONF_LOG_FILE

        # Calculate random hour
        # The max random time can be 23:59:59
        rand_hr=`awk -v min=0 -v max=23 -v seed="$(date +%N)" 'BEGIN{srand(seed);print int(min+rand()*(max-min+1))}'`

        echo_t "XCONF SCRIPT : Time Generated : $rand_hr hr $rand_min min $rand_sec sec"
        min_to_sleep=$(($rand_hr*60 + $rand_min))
        sec_to_sleep=$(($min_to_sleep*60 + $rand_sec))

        printf "XCONF SCRIPT : Checking update with XCONF server at \t";
        # date -d "$min_to_sleep minutes" +'%H:%M:%S'
        date -d @"$(( `date +%s`+$sec_to_sleep ))"

        date_upgch_part="$(( `date +%s`+$sec_to_sleep ))"
        date_upgch_final=`date -d @"$date_upgch_part"`

        echo_t "Checking update on $date_upgch_final" >> $XCONF_LOG_FILE

    fi

    #
    # Generate time to downlaod HTTP image
    # device reboot time 
    #
    if [ $2 -eq '1' ]; then

        if [ "$3" == "r" ]; then
            echo_t "XCONF SCRIPT : Device reboot time being calculated in maintenance window"
            echo_t "XCONF SCRIPT : Device reboot time being calculated in maintenance window" >> $XCONF_LOG_FILE
        fi

        if [ "$start_time" -gt "$end_time" ]
        then
            start_time=$(($start_time-86400))
        fi

        #Calculate random value
        random_time=`awk -v min=$start_time -v max=$end_time 'BEGIN{srand(); print int(min+rand()*(max-min+1))}'`

        if [ $random_time -le 0 ]
        then
            random_time=$((random_time+86400))
        fi
        random_time_in_sec=$random_time

        # Calculate random second
        rand_sec=$((random_time%60))

        # Calculate random min
        random_time=$((random_time/60))
        rand_min=$((random_time%60))

        # Calculate random hour
        random_time=$((random_time/60))
        rand_hr=$((random_time%60))

        echo_t "XCONF SCRIPT : Time Generated : $rand_hr hr $rand_min min $rand_sec sec"
        echo_t "XCONF SCRIPT : Time Generated : $rand_hr hr $rand_min min $rand_sec sec" >> $XCONF_LOG_FILE

        # Get current time
        if [ "$UTC_ENABLE" == "true" ]
        then
            cur_hr=`LTime H | sed 's/^0*//'`
            cur_min=`LTime M | sed 's/^0*//'`
            cur_sec=`date +"%S" | sed 's/^0*//'`
        else
            cur_hr=`date +"%H" | sed 's/^0*//'`
            cur_min=`date +"%M" | sed 's/^0*//'`
            cur_sec=`date +"%S" | sed 's/^0*//'`
        fi
        echo_t "XCONF SCRIPT : Current Local Time: $cur_hr hr $cur_min min $cur_sec sec" >> $XCONF_LOG_FILE

        curr_hr_in_sec=$((cur_hr*60*60))
        curr_min_in_sec=$((cur_min*60))
        curr_time_in_sec=$((curr_hr_in_sec+curr_min_in_sec+cur_sec))
        echo_t "XCONF SCRIPT : Current Time in secs: $curr_time_in_sec sec" >> $XCONF_LOG_FILE

        if [ $curr_time_in_sec -le $random_time_in_sec ]
        then
            sec_to_sleep=$((random_time_in_sec-curr_time_in_sec))
        else
            sec_to_12=$((86400-curr_time_in_sec))
            sec_to_sleep=$((sec_to_12+random_time_in_sec))
        fi

        time=$(( `date +%s`+$sec_to_sleep ))
        date_final=`date -d @${time} +"%T"`

        echo_t "Action on $date_final"
        echo_t "Action on $date_final" >> $XCONF_LOG_FILE
        touch $REBOOT_WAIT

    fi

    echo_t "XCONF SCRIPT : SLEEPING FOR $sec_to_sleep seconds"
    echo_t "XCONF SCRIPT : SLEEPING FOR $sec_to_sleep seconds" >> $XCONF_LOG_FILE

    sleep $sec_to_sleep
    echo_t "XCONF script : got up after $sec_to_sleep seconds"
    echo_t "XCONF script : got up after $sec_to_sleep seconds" >> $XCONF_LOG_FILE
}

# Get the MAC address of the WAN interface
getMacAddress()
{
    ifconfig  | grep $wan_interface |  grep -v $wan_interface:0 | tr -s ' ' | cut -d ' ' -f5
}

getBuildType()
{
   IMAGENAME=`grep "imagename" /version.txt | cut -d ":" -f 2`

   TEMPDEV=`echo $IMAGENAME | grep DEV`
   if [ "$TEMPDEV" != "" ]
   then
       type="DEV"
   fi

   TEMPVBN=`echo $IMAGENAME | grep VBN`
   if [ "$TEMPVBN" != "" ]
   then
       type="VBN"
   fi

   TEMPPROD=`echo $IMAGENAME | grep PROD`
   if [ "$TEMPPROD" != "" ]
   then
       type="PROD"
   fi

   TEMPCQA=`echo $IMAGENAME | grep CQA`
   if [ "$TEMPCQA" != "" ]
   then
       type="GSLB"
   fi
   
   if [ "$type" = "" ]
   then
       type="DEV"
   fi
   
   echo_t "XCONF SCRIPT : image_type is $type"
   echo_t "XCONF SCRIPT : image_type is $type" >> $XCONF_LOG_FILE
}

 
removeLegacyResources()
{
	#moved Xconf logging to /var/tmp/xconf.txt.0
    if [ -f /tmp/Xconf.log ]; then
	rm /tmp/Xconf.log
    fi

	echo_t "XCONF SCRIPT : Done Cleanup"
	echo_t "XCONF SCRIPT : Done Cleanup" >> $XCONF_LOG_FILE
}

# Check if it is still in maintenance window
checkMaintenanceWindow()
{
    if [ -f "$FW_START" ] && [ -f "$FW_END" ]
    then
      start_time=`cat $FW_START`
      end_time=`cat $FW_END`
    fi

    if [ "$start_time" = "$end_time" ]
    then
        echo_t "XCONF SCRIPT : Start time can not be equal to end time"
        echo_t "XCONF SCRIPT : Resetting values to default"
        echo_t "XCONF SCRIPT : Start time can not be equal to end time" >> $XCONF_LOG_FILE
	t2CountNotify "Test_StartEndEqual"
        echo_t "XCONF SCRIPT : Resetting values to default" >> $XCONF_LOG_FILE
        start_time=0
        end_time=10800
        echo "$start_time" > $FW_START
        echo "$end_time" > $FW_END
   fi

    echo_t "XCONF SCRIPT : Firmware upgrade start time : $start_time"
    echo_t "XCONF SCRIPT : Firmware upgrade start time : $start_time" >> $XCONF_LOG_FILE
    echo_t "XCONF SCRIPT : Firmware upgrade end time : $end_time"
    echo_t "XCONF SCRIPT : Firmware upgrade end time : $end_time" >> $XCONF_LOG_FILE

    if [ "$UTC_ENABLE" == "true" ]
    then
        reb_hr=`LTime H | sed 's/^0*//'`
        reb_min=`LTime M | sed 's/^0*//'`
        reb_sec=`date +"%S" | sed 's/^0*//'`
    else
        reb_hr=`date +"%H" | sed 's/^0*//'`
        reb_min=`date +"%M" | sed 's/^0*//'`
        reb_sec=`date +"%S" | sed 's/^0*//'`
    fi

    reb_window=0
    reb_hr_in_sec=$((reb_hr*60*60))
    reb_min_in_sec=$((reb_min*60))
    reb_time_in_sec=$((reb_hr_in_sec+reb_min_in_sec+reb_sec))
    echo_t "XCONF SCRIPT : Current time in seconds : $reb_time_in_sec"
    echo_t "XCONF SCRIPT : Current time in seconds : $reb_time_in_sec" >> $XCONF_LOG_FILE

    if [ $start_time -lt $end_time ] && [ $reb_time_in_sec -ge $start_time ] && [ $reb_time_in_sec -lt $end_time ]
    then
        reb_window=1
    elif [ $start_time -gt $end_time ] && [[ $reb_time_in_sec -lt $end_time || $reb_time_in_sec -ge $start_time ]]
    then
        reb_window=1
    else
        reb_window=0
    fi
}

# Check RFC processing and signal rfc agent to start processing
checkrfcstatus()
{
    if [ -f "$RFC_JSON" ] && [ ! -f "$PROCESSING_RFC" ]; then
      echo_t "XCONF SCRIPT : Processing RFC file"
      echo_t "XCONF SCRIPT : Processing RFC file" >> $XCONF_LOG_FILE
      touch $APPLY_RFC
      sleep 30
    fi
    count=0
    #Wait here till the RFC's are processed or 10 minutes
    while [ -f "$PROCESSING_RFC" ] && [ $count -lt 60 ]; do
        count=$((count + 1))
        sleep 10
        if [ $count -eq 60 ]; then
            echo_t "XCONF SCRIPT : Timed out for RFC processing"
            echo_t "XCONF SCRIPT : Timed out for RFC processing" >> $XCONF_LOG_FILE
        fi
        if [ ! -f "$PROCESSING_RFC" ]; then
            echo_t "XCONF SCRIPT : RFC processing done"
            echo_t "XCONF SCRIPT : RFC processing done" >> $XCONF_LOG_FILE
        fi
    done
}

#####################################################Main Application#####################################################

# Determine the env type and url and write to /tmp/Xconf
#type=`printenv model | cut -d "=" -f2`

removeLegacyResources
getBuildType

# Check if the firmware download process is initiated by scheduler or during boot up.
triggeredFrom=""
if [[ $1 -eq 1 ]]
then
   echo_t "XCONF SCRIPT : Trigger is from boot" >> $XCONF_LOG_FILE
   triggeredFrom="boot"
elif [[ $1 -eq 2 ]]
then
   echo_t "XCONF SCRIPT : Trigger is from cron" >> $XCONF_LOG_FILE
   triggeredFrom="cron"
elif [[ $1 -eq 5 ]]
then
   echo_t "XCONF SCRIPT : Trigger from delayDownload Timer" >> $XCONF_LOG_FILE
   triggeredFrom="delayedDownload"
else
   echo_t "XCONF SCRIPT : Trigger is Unknown. Set it to boot" >> $XCONF_LOG_FILE
   triggeredFrom="boot"
fi

# If unit is waiting for reboot after image download,we need not have to download image again.
if [ -f $REBOOT_WAIT ]
then
    echo_t "XCONF SCRIPT : Waiting reboot after download, so exit" >> $XCONF_LOG_FILE
    exit
fi

if [ -f $DOWNLOAD_INPROGRESS ]
then
    echo_t "XCONF SCRIPT : Download is in progress, exit" >> $XCONF_LOG_FILE
    exit    
fi

if [ "$type" = "DEV" ] || [ "$type" = "dev" ];then
    url="https://ci.xconfds.ccp.xcal.tv/xconf/swu/stb/"
else
    url="https://xconf.xcal.tv/xconf/swu/stb/"
fi
# Verify 3x that we dont have bootrom_otp=1 before allowing the override
bootrom_otp=0
for otp_try in `seq 1 3`
do
    grep bootrom_otp=1 /proc/cmdline >/dev/null
    if [ $? -eq 0 ]; then
        bootrom_otp=1
    fi
done
if [ "$bootrom_otp" -eq 0 ]; then
    if [ -f /nvram/swupdate.conf ] ; then
        url=`grep -v '^[[:space:]]*#' /nvram/swupdate.conf`
      echo_t "XCONF SCRIPT : URL taken from /nvram/swupdate.conf override. URL=$url"
      echo_t "XCONF SCRIPT : URL taken from /nvram/swupdate.conf override. URL=$url"  >> $XCONF_LOG_FILE
    else
        # RFC override should work only for non-production build
        url_override=`syscfg get AutoExcludedURL`
        if [ "$url_override" ] && [ "$type" != "PROD" ] && [ $BUILD_TYPE != "prod" ] ; then
           url=$url_override
        fi
    fi
fi

echo_t "XCONF SCRIPT : Device retrieves firmware update from url=$url"

#s16 echo "$type=$url" > /tmp/Xconf
echo "URL=$url" > /tmp/Xconf
echo_t "XCONF SCRIPT : Values written to /tmp/Xconf are URL=$url"
echo_t "XCONF SCRIPT : Values written to /tmp/Xconf are URL=$url" >> $XCONF_LOG_FILE

# Check if the WAN interface has an ip address, if not , wait for it to receive one
estbIp=`ifconfig $interface | grep "inet addr" | tr -s " " | cut -d ":" -f2 | cut -d " " -f1`
estbIp6=`ifconfig $interface | grep "inet6 addr" | grep "Global" | tr -s " " | cut -d ":" -f2- | cut -d "/" -f1 | tr -d " "`

echo "[ $(date) ] XCONF SCRIPT - Check if the WAN interface has an ip address" >> $XCONF_LOG_FILE

while [ "$estbIp" = "" ] && [ "$estbIp6" = "" ]
do
    echo "[ $(date) ] XCONF SCRIPT - No IP yet! sleep(5)" >> $XCONF_LOG_FILE
    sleep 5
    interface=$(getWanInterfaceName)

    estbIp=`ifconfig $interface | grep "inet addr" | tr -s " " | cut -d ":" -f2 | cut -d " " -f1`
    estbIp6=`ifconfig $interface | grep "inet6 addr" | grep "Global" | tr -s " " | cut -d ":" -f2- | cut -d "/" -f1 | tr -d " "`

    echo_t "XCONF SCRIPT : Sleeping for an ipv4 or an ipv6 address on the $interface interface "
done

echo_t "XCONF SCRIPT : $interface has an ipv4 address of $estbIp or an ipv6 address of $estbIp6"

    ######################
    # QUERY & DL MANAGER #
    ######################

# Checking Autoupdate exclusion
FWUPGRADE_EXCLUDE=`syscfg get AutoExcludedEnabled`
if [ x$FWUPGRADE_EXCLUDE != "x" ];then
    echo_t "FWExclusion status is : $FWUPGRADE_EXCLUDE"
fi

# Triggered after delayedDownload timer expired
if [ "$triggeredFrom" = "delayedDownload" ];
then
   fetchFirmwareDetail
fi

# Check if new image is available
echo_t "XCONF SCRIPT : Checking image availability at boot up" >> $XCONF_LOG_FILE	
if [ ! -e $NO_DOWNLOAD ] && [ $image_upg_avl -eq 0 ];
then	
getFirmwareUpgDetail
fi
Retry_Reboot_count=0
if [ "$factoryResetImmediately" == "true" ];then
    echo_t "XCONF SCRIPT : factoryResetImmediately : TRUE!!" >> $XCONF_LOG_FILE
    echo_t "XCONF SCRIPT : firmwareLocation: $firmwareLocation firmwareFilename : $firmwareFilename" >> $XCONF_LOG_FILE
    while [ $Retry_Reboot_count -lt 3 ]; do
        $BIN_PATH/XconfHttpDl upgrade_factoryreset "$firmwareLocation" "$firmwareFilename" >> $XCONF_LOG_FILE
        reboot_device=$?
        if [ $reboot_device -eq 0 ];then
    	    echo_t "XCONF SCRIPT : factory resetting and upgrading the image" >> $XCONF_LOG_FILE
            break
        else
            echo_t "XCONF SCRIPT : Failed to upgrade and factory reset retrying...$Retry_Reboot_count" >> $XCONF_LOG_FILE
            Retry_Reboot_count=$((Retry_Reboot_count+1))
        fi
    done
    if [ $Retry_Reboot_count -eq 3 ];then
        echo_t "XCONF SCRIPT : Failed to upgrade after max 3 retires.. exiting !!!" >> $XCONF_LOG_FILE
    fi
    exit
fi

if [ "$rebootImmediately" == "true" ];then
    echo_t "XCONF SCRIPT : Reboot Immediately : TRUE!!"
else
    echo_t "XCONF SCRIPT : Reboot Immediately : FALSE."

fi    

download_image_success=0
reboot_device_success=0
retry_download=0
http_flash_led_disable=0
is_already_flash_led_disable=0

while [ $download_image_success -eq 0 ]; 
do
    
    #skip download if file exist
    if [ -f $NO_DOWNLOAD ]
    then
       break
    fi

    if [ "$isPeriodicFWCheckEnabled" != "true" ]
    then
       # If an image wasn't available, check it's 
       # availability at a random time,every 24 hrs
       while  [ $image_upg_avl -eq 0 ];
       do

         interface=$(getWanInterfaceName)
         echo_t "XCONF SCRIPT : Rechecking image availability within 24 hrs" 
         echo_t "XCONF SCRIPT : Rechecking image availability within 24 hrs" >> $XCONF_LOG_FILE

         # Sleep for a random time less than 
         # a 24 hour duration 
         if [ $maintenance_window_mode -eq 0 ]; then
            calcRandTime 1 0
         else
            calcRandTimeBCI 1 0
         fi
    
         # Check for the availability of an update   
         getFirmwareUpgDetail
       done
    fi

    if [ $image_upg_avl -eq 1 ];then
        if [ ! -f $DOWNLOAD_INPROGRESS ]
        then
            touch $DOWNLOAD_INPROGRESS
        fi
       echo "$firmwareLocation" > /tmp/xconfdownloadurl

       if [ "$curr_conn_type" = "direct" ]; then
          # Set the url and filename
          echo_t "XCONF SCRIPT : URL --- $firmwareLocation and NAME --- $firmwareFilename"
          echo_t "XCONF SCRIPT : URL --- $firmwareLocation and NAME --- $firmwareFilename" >> $XCONF_LOG_FILE
          CURL_CMD_SSR="curl $CERT_STATUS --connect-timeout 30 --tlsv1.2 --interface $interface $addr_type -w '%{http_code}\n' -fgLo $TMP_PATH/$firmwareFilename '$firmwareLocation/$firmwareFilename'"
          echo_t "Direct CURL_CMD : $CURL_CMD_SSR"
          echo_t "Direct CURL_CMD : $CURL_CMD_SSR" >> $XCONF_LOG_FILE
#          $BIN_PATH/XconfHttpDl set_http_url "$firmwareLocation" "$firmwareFilename"
       else
          # Set the url and filename
          echo_t "XCONF SCRIPT : URL --- `echo $serverUrl |  sed -e  's/oauth_consumer_key=.*oauth_signature=.*/<hidden>/g'` and NAME --- $firmwareFilename"
          echo_t "XCONF SCRIPT : URL --- `echo $serverUrl | sed -e  's/oauth_consumer_key=.*oauth_signature=.*/<hidden>/g'` and NAME --- $firmwareFilename" >> $XCONF_LOG_FILE
          echo_t "Codebig CURL_CMD :`echo  "$CURL_CMD_SSR" |  sed -e  's/oauth_consumer_key=.*oauth_signature=.*/<hidden>/g'`"
          echo_t "Codebig CURL_CMD :`echo  "$CURL_CMD_SSR" |  sed -e  's/oauth_consumer_key=.*oauth_signature=.*/<hidden>/g'`" >> $XCONF_LOG_FILE
#          $BIN_PATH/XconfHttpDl set_http_url "$serverUrl" "$firmwareFilename"
       fi

       set_url_stat=$?
        
       # If the URL was correctly set, initiate the download
       if [ $set_url_stat -eq 0 ];then
        
           # An upgrade is available and the URL has ben set 
           # Wait to download in the maintenance window if the RebootImmediately is FALSE
           # else download the image immediately

           if [ "$rebootImmediately" == "false" ];then
              echo_t "XCONF SCRIPT : Reboot Immediately : FALSE. Downloading image now" >> $XCONF_LOG_FILE
           else
              echo_t  "XCONF SCRIPT : Reboot Immediately : TRUE : Downloading image now" >> $XCONF_LOG_FILE
           fi
	 
	    echo "XCONF SCRIPT : Sleep 5s to prevent gw refresh error"
	    echo "XCONF SCRIPT : Sleep 5s to prevent gw refresh error" >> $XCONF_LOG_FILE

            sleep 5

		#Trigger FirmwareDownloadStartedNotification before commencement of firmware download

		current_time=`date +%s`
		echo_t "current_time calculated as $current_time" >> $XCONF_LOG_FILE
		if [ "$rebootImmediately" == "true" ];then
			reboot_flag="forced"
		else
			reboot_flag="deferred"
		fi
		FW_DWLD_NOTIFICATION_STRING="$current_time,$reboot_flag,$current_FW_Version,$update_FW_Version"
		echo_t "XCONF SCRIPT : FirmwareDownloadStartedNotification parameters are $FW_DWLD_NOTIFICATION_STRING" >> $XCONF_LOG_FILE
		dmcli eRT setv Device.DeviceInfo.X_RDKCENTRAL-COM_xOpsDeviceMgmt.RPC.FirmwareDownloadStartedNotification string $FW_DWLD_NOTIFICATION_STRING
		echo_t "XCONF SCRIPT : FirmwareDownloadStartedNotification SET is triggered" >> $XCONF_LOG_FILE

           # Start the image download
           echo_t "XCONF SCRIPT  ### httpdownload started ###" >> $XCONF_LOG_FILE
# Check for direct/codebig not required : as CMD already set. 
##################################################################################################################################################
#	Following code will loop through 5 times to download image.
#       Code Flow:
#               Retry downloading for "numberOfTries" times if download fails until numberOfTries hasn't met otherwise exit if succeeded.  
#               Determine success/failure based on following errors 1) file not available 2) connection error 
#		3) if partial file was downloaded 4) if nothing was returned from server 5) Network failure 6)other failures
#               If full file was successfully downloaded then invoke OEM to flash it on device
##################################################################################################################################################
           currentTry=0
           numberOfTries=5
           while [ $currentTry -lt $numberOfTries ]; 
           do
		HTTP_CODE=`result= eval $CURL_CMD_SSR`
		curl_code=$?
		HTTP_RESPONSE_CODE=$(echo "$HTTP_CODE" | awk -F\" '{print $1}' )
		echo_t "XCONF SCRIPT : Direct CURL_CMD_SSR : $CURL_CMD_SSR" >> $XCONF_LOG_FILE  
		echo_t "XCONF SCRIPT : curl_code:$curl_code, http_code:$HTTP_RESPONSE_CODE"  >> $XCONF_LOG_FILE
		[ "x$HTTP_RESPONSE_CODE" != "x" ] || HTTP_RESPONSE_CODE=0    
		if [ "x$curl_code" ==  "x0" ] && [ "x$HTTP_RESPONSE_CODE" == "x200" ] ; then
                    echo_t "XCONF SCRIPT : Breaking the download loop as Download is successful. curl_code:$curl_code, http_code:$HTTP_RESPONSE_CODE" >> $XCONF_LOG_FILE
                    http_dl_stat=0
                    break
                else 
                    echo_t "XCONF SCRIPT : curl error code: $curl_code, http_code: $HTTP_RESPONSE_CODE"  >> $XCONF_LOG_FILE
                    #cleanup 
                    rm $TMP_PATH/$firmwareFilename$
                    http_dl_stat=1
                    if [ "x$curl_code" == "x23" ] || [ "x$curl_code" == "x25" ] || [ "x$curl_code" == "x26" ]; then
                        #file errors 23,25,26
                        echo_t "XCONF SCRIPT : Curl did not find file on server in $currentTry attempt. curl error code: $curl_code" >> $XCONF_LOG_FILE
                    elif [ "x$curl_code" == "x5" ] || [ "x$curl_code" == "x6" ] || [ "x$curl_code" == "x7" ]; then
                        #connection errors 5,6,7
                        echo_t "XCONF SCRIPT : Curl could not connect to server in $currentTry attempt. curl error code: $curl_code" >> $XCONF_LOG_FILE
                    elif [ "x$curl_code" == "x18" ] || [ "x$curl_code" == "x19" ]; then
                        #partial file download errors 18,19
                        echo_t "XCONF SCRIPT : Curl could not download full file from server in $currentTry attempt. curl error code: $curl_code" >> $XCONF_LOG_FILE
                    elif [ "x$curl_code" == "x52" ]; then
                        #server did not return anything errors 52
                        echo_t "XCONF SCRIPT : Curl could not retrieve anything from server in $currentTry attempt. curl error code: $curl_code" >> $XCONF_LOG_FILE
                    elif [ "x$curl_code" == "x55" ] || [ "x$curl_code" == "x56" ]; then
                        #Failure with network data 55,56
                        echo_t "XCONF SCRIPT : Curl failure with network data in $currentTry attempt. curl error code: $curl_code" >> $XCONF_LOG_FILE
                    else
                        #other errors
                        echo_t "XCONF SCRIPT : Unknown Curl error in $currentTry attempt. curl error code: $curl_code" >> $XCONF_LOG_FILE
                    fi


                    if [ $currentTry -eq $numberOfTries ]; then
                        echo_t "XCONF SCRIPT : Something went wrong tried to download $numberOfTries times but did not succeed. Exiting" >> $XCONF_LOG_FILE
                    else
                        echo_t "XCONF SCRIPT : Something went wrong tried to download $currentTry times but did not succeed. Will try again..." >> $XCONF_LOG_FILE
                        let currentTry=$currentTry+1
                    fi
                fi
           done
          if [ "x$HTTP_RESPONSE_CODE" = "x200" ] ; then
               http_dl_stat=0
               echo_t "XCONF SCRIPT  ### httpdownload completed ###" >> $XCONF_LOG_FILE
           else
               http_dl_stat=1
           fi
           echo_t "**XCONF SCRIPT : HTTP DL STATUS $http_dl_stat**" >> $XCONF_LOG_FILE
			
           # If the http_dl_stat is 0, the download was succesful,          
           # Indicate a succesful download and continue to the reboot manager
		
            if [ $http_dl_stat -eq 0 ];then
                echo_t "XCONF SCRIPT : HTTP download Successful" >> $XCONF_LOG_FILE
		t2CountNotify "XCONF_Dwld_success"
                uptime=`cat /proc/uptime | awk '{ print $1 }' | cut -d"." -f1`
                echo_t "XCONF SCRIPT : xconf download is success:$uptime" >> $XCONF_LOG_FILE
                t2ValNotify "xconf_download_success" "$uptime"
                # Indicate succesful download
                download_image_success=1
                rm -rf $DOWNLOAD_INPROGRESS

                #Trigger FirmwareDownloadCompletedNotification after firmware download
                dmcli eRT setv Device.DeviceInfo.X_RDKCENTRAL-COM_xOpsDeviceMgmt.RPC.FirmwareDownloadCompletedNotification bool true
		echo_t "FirmwareDownloadCompletedNotification SET to true is triggered" >> $XCONF_LOG_FILE
            else
                # Indicate an unsuccesful download
                echo_t "XCONF SCRIPT : HTTP download NOT Successful" >> $XCONF_LOG_FILE
		t2CountNotify "XCONF_Dwld_failed"
                rm -rf $DOWNLOAD_INPROGRESS
                download_image_success=0
                # Set the flag to 0 to force a requery
                image_upg_avl=0

                #Trigger FirmwareDownloadCompletedNotification after firmware download
                dmcli eRT setv Device.DeviceInfo.X_RDKCENTRAL-COM_xOpsDeviceMgmt.RPC.FirmwareDownloadCompletedNotification bool false
		echo_t "FirmwareDownloadCompletedNotification SET to false is triggered" >> $XCONF_LOG_FILE

                if [ "$isPeriodicFWCheckEnabled" == "true" ]; then
			# No need of looping here as we will trigger a cron job at random time
			exit
		fi
           fi
       else
                download_image_success=0
            	# Set the flag to 0 to force a requery
            	image_upg_avl=0
                rm -rf $DOWNLOAD_INPROGRESS
 	       if [ "$isPeriodicFWCheckEnabled" == "true" ]; then
          	   retry_download=`expr $retry_download + 1`
		       
        	   if [ $retry_download -eq 3 ]
          	   then
             	       echo_t "XCONF SCRIPT : ERROR : URL & Filename not set correctly after 3 retries.Exiting" >> $XCONF_LOG_FILE
        	       exit  
          	   fi
               fi
       fi
    fi

    if [ $download_image_success -eq 1 ]; then    
      #download completed, let's flash the image
      flash_image_success=0
      flash_image_count=0

      while [ $flash_image_success -eq 0 ] && [ $flash_image_count -lt 3 ];
      do
	echo "XCONF SCRIPT : Flashing Filename : $TMP_PATH/$firmwareFilename to flash! "
	#$BIN_PATH/tftp -p -b 1400 -l "$TMP_PATH/$firmwareFilename" -r $firmwareFilename 172.31.255.45
	$BIN_PATH/xf3_sw_install "$TMP_PATH/$firmwareFilename"
	flash_ret=$?
	if [ $flash_ret -eq 0 ]; then
	  flash_image_success=1
	  echo "XCONF SCRIPT : Flashing Filename : $firmwareFilename Successful! "
	  echo "XCONF SCRIPT : Flashing Filename : $firmwareFilename Successful! " >> $XCONF_LOG_FILE
	else
	  echo "XCONF SCRIPT : Flashing Filename : $firmwareFilename Not Successful! "
	  echo "XCONF SCRIPT : Flashing Filename : $firmwareFilename Not Successful! " >> $XCONF_LOG_FILE
	  t2CountNotify "XCONF_flash_failed"
	fi
	
	flash_image_count=$((flash_image_count + 1))
      done

      if [ $flash_image_success -eq 0 ]; then
         # flash failed, try it again in the near future
         download_image_success=0
         image_upg_avl=0
                         
	 if [ "$isPeriodicFWCheckEnabled" == "true" ]; then
            # No need of looping here as we will trigger a cron job at random time
            exit
         fi
      fi
    fi
done

    ##################
    # REBOOT MANAGER #
    ##################

    # Try rebooting the device if :
    # 1. Issue an immediate reboot if still within the maintenance window and phone is on hook
    # 2. If an immediate reboot is not possile ,calculate and remain within the reboot maintenance window
    # 3. The reboot ready status is OK within the maintenance window 
    # 4. The rebootImmediate flag is set to true

while [ $reboot_device_success -eq 0 ]; do
                    
    # Verify reboot criteria ONLY if rebootImmediately is FALSE
    if [ "$rebootImmediately" == "false" ];then

        # Check if still within reboot window
        checkMaintenanceWindow

        if [ $reb_window -eq 1 ]; then
            echo_t "XCONF SCRIPT : Still within current maintenance window for reboot"
            echo_t "XCONF SCRIPT : Still within current maintenance window for reboot" >> $XCONF_LOG_FILE
            reboot_now=1
        else
            echo_t "XCONF SCRIPT : Not within current maintenance window for reboot.Rebooting in the next window"
            echo_t "XCONF SCRIPT : Not within current maintenance window for reboot.Rebooting in the next window" >> $XCONF_LOG_FILE
            reboot_now=0
        fi


        if [ $reboot_now -eq 0 ] && [ $is_already_flash_led_disable -eq 0 ];
		then
			echo "XCONF SCRIPT	: ### httpdownload flash LED disabled ###" >> $XCONF_LOG_FILE
			$BIN_PATH/XconfHttpDl http_flash_led $http_flash_led_disable
            is_already_flash_led_disable=1
        fi    

        # If we are not supposed to reboot now, calculate random time
        # to reboot in next maintenance window 
        if [ $reboot_now -eq 0 ];then
            if [ $maintenance_window_mode -eq 0 ]; then
                calcRandTime 0 1 r
            else
                calcRandTimeBCI 0 1 r
            fi
        fi    

        checkrfcstatus
 
        # Check the Reboot status
        # Continously check reboot status every 10 seconds  
        # till the end of the maintenace window until the reboot status is OK
        $BIN_PATH/XconfHttpDl http_reboot_status
        http_reboot_ready_stat=$?

        while [ $http_reboot_ready_stat -eq 1 ]   
        do    
            sleep 10
            checkMaintenanceWindow

            if [ $reb_window -eq 1 ]
            then
                #We're still within the reboot window 
                $BIN_PATH/XconfHttpDl http_reboot_status
                http_reboot_ready_stat=$?
                    
            else
                #If we're out of the reboot window, exit while loop
                break
            fi
        done 

    else
        checkrfcstatus
        #RebootImmediately is TRUE
        echo_t "XCONF SCRIPT : Reboot Immediately : TRUE!, rebooting device now"
        http_reboot_ready_stat=0    
        echo_t "XCONF SCRIPT : http_reboot_ready_stat is $http_reboot_ready_stat"
                            
    fi 
                    
    echo_t "XCONF SCRIPT : http_reboot_ready_stat is $http_reboot_ready_stat" >> $XCONF_LOG_FILE

    # The reboot ready status changed to OK within the maintenance window,proceed
    if [ $http_reboot_ready_stat -eq 0 ];then
		        
	if [ $abortReboot_count -lt 5 ];then
		#Wait for Notification to propogate
		deferfw=`dmcli eRT getv Device.DeviceInfo.X_RDKCENTRAL-COM_xOpsDeviceMgmt.RPC.DeferFWDownloadReboot | grep value | cut -d ":" -f 3 | tr -d ' ' `
		echo_t "XCONF SCRIPT : Sleeping for $deferfw seconds before reboot" >> $XCONF_LOG_FILE
		touch $deferReboot 
		dmcli eRT setv Device.DeviceInfo.X_RDKCENTRAL-COM_xOpsDeviceMgmt.RPC.RebootPendingNotification uint $deferfw
		sleep $deferfw
	else
		echo_t "XCONF SCRIPT : Abort Count reached maximum limit $abortReboot_count" >> $XCONF_LOG_FILE
	fi


      if [ ! -e "$ABORT_REBOOT" ]
      then
        #Reboot the device
        echo_t "XCONF SCRIPT : Reboot possible. Issuing reboot command"
        echo_t "RDKB_REBOOT : Reboot command issued from XCONF"
	echo_t "XCONF SCRIPT : setting LastRebootReason"
        if [ -f "$PENDING_RFC_REBOOT" ]; then
            dmcli eRT setv Device.DeviceInfo.X_RDKCENTRAL-COM_LastRebootReason string Software_upgrade_and_RFC
        else
            dmcli eRT setv Device.DeviceInfo.X_RDKCENTRAL-COM_LastRebootReason string Software_upgrade
        fi
        echo_t "XCONF SCRIPT : SET succeeded"

        #For rdkb-4260
        echo_t "Creating file /nvram/reboot_due_to_sw_upgrade"
        touch /nvram/reboot_due_to_sw_upgrade
        echo_t "XCONF SCRIPT : REBOOTING DEVICE"
        echo_t "RDKB_REBOOT : Rebooting device due to software upgrade"
	
	sh /rdklogger/backupLogs.sh false
        $BIN_PATH/XconfHttpDl http_reboot 
        reboot_device=$?
		       
        # This indicates we're within the maintenace window/rebootImmediate=TRUE
        # and the reboot ready status is OK, issue the reboot
        # command and check if it returned correctly
        if [ $reboot_device -eq 0 ];then
            reboot_device_success=1
            echo "XCONF SCRIPT : REBOOTING DEVICE"            
                
        else 
            # The reboot command failed, retry in the next maintenance window 
            reboot_device_success=0
            #Goto start of Reboot Manager again  
        fi
      else 
                echo_t "XCONF SCRIPT : Reboot aborted by user, will try in next maintenance window " >> $XCONF_LOG_FILE
		abortReboot_count=$((abortReboot_count+1))
		echo_t "XCONF SCRIPT : Abort Count is  $abortReboot_count" >> $XCONF_LOG_FILE
                touch $NO_DOWNLOAD
                rm -rf $ABORT_REBOOT
                rm -rf $deferReboot
                reboot_device_success=0

		while [ 1 ]
		do
		    checkMaintenanceWindow

		    if [ $reb_window -eq 1 ]
		    then
		        #We're still within the maintenance window, sleeping for 2 hr to come out of maintenance window
		        sleep 7200
		    else
		        #If we're out of the maintenance window, exit while loop
		        break
		    fi
		done
      fi

     # The reboot ready status didn't change to OK within the maintenance window 
     else
        reboot_device_success=0
        echo_t " XCONF SCRIPT : Device is not ready to reboot : Retrying in next reboot window ";
        # Goto start of Reboot Manager again  
     fi
                    
done # While loop for reboot manager
