/*
 * If not stated otherwise in this file or this component's Licenses.txt file the
 * following copyright and licenses apply:
 *
 * Copyright 2017 RDK Management
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 * http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
*/
#include <stdio.h>
#include <unistd.h>
#include <string.h>

#include <telemetry_busmessage_sender.h>
#include <syscfg/syscfg.h>

#include "cm_hal.h"
#include "safec_lib_common.h"
#include <sys/stat.h>
#include "secure_wrapper.h"

#if defined(_ENABLE_EPON_SUPPORT_)
#include "dpoe_hal.h"
#endif

#define RETRY_HTTP_DOWNLOAD_LIMIT 3
#define RETURN_OK 0
#define LONG long
#define CM_HTTPURL_LEN 1024
#define CM_FILENAME_LEN 200
#define NUM_OF_ARGUMENT_TYPES (sizeof(argument_type_xconf_table)/sizeof(argument_type_xconf_table[0]))
#ifdef FEATURE_RDKB_LED_MANAGER
#include <sysevent/sysevent.h>
#define SYS_IP_ADDR    "127.0.0.1"
#define SYSEVENT_LED_STATE    "led_event"
#define FW_DOWNLOAD_START_EVENT "rdkb_fwdownload_start"
#define FW_UPDATE_STOP_EVENT "rdkb_fwupdate_stop"
#define FW_UPDATE_COMPLETE_EVENT "rdkb_fwupdate_complete"
int sysevent_led_fd = -1;
token_t sysevent_led_token;
#ifdef FEATURE_RDKB_LED_MANAGER_CAPTIVE_PORTAL
#define HTTP_LED_FLASH_DISABLE_FLAG "/tmp/.dwd_led_blink_disable"
#define FW_DOWNLOAD_STOP "rdkb_fwdownload_stop"
#define FW_DOWNLOAD_STOP_CAPTIVEMODE "rdkb_fwdownload_stop_captivemode"
#endif
#endif

enum ArgumentType_Xconf_e {
    SET_HTTP_URL,
    HTTP_DOWNLOAD,
    HTTP_REBOOT_STATUS,
    HTTP_REBOOT,
    HTTP_FLASH_LED,
    UPGRADE_FACTORYRESET
};

typedef struct ArgumentType_Pair_For_Xconf{
  char                 *name;
  enum ArgumentType_Xconf_e  type;
} ARGUMENT_TYPE_PAIR_FOR_XCONF;

ARGUMENT_TYPE_PAIR_FOR_XCONF argument_type_xconf_table[] = {
  {"set_http_url",          SET_HTTP_URL        },
  {"http_download",         HTTP_DOWNLOAD       },
  {"http_reboot_status",    HTTP_REBOOT_STATUS  },
  {"http_reboot",           HTTP_REBOOT         },
  {"http_flash_led",        HTTP_FLASH_LED      },
  {"upgrade_factoryreset",  UPGRADE_FACTORYRESET}
};

static int get_argument_type_from_argv(char *name, enum ArgumentType_Xconf_e *type_ptr)
{
  errno_t rc = -1;
  int ind = -1;
  int i = 0;
  size_t strsize = 0;

  if((name == NULL) || (type_ptr == NULL))
     return 0;

  strsize = strlen(name);

  for (i = 0 ; i < NUM_OF_ARGUMENT_TYPES ; ++i)
  {
      rc = strcmp_s(name, strsize, argument_type_xconf_table[i].name, &ind);
      ERR_CHK(rc);
      if((rc == EOK) && (!ind))
      {
          *type_ptr = argument_type_xconf_table[i].type;
          return 1;
      }
  }
  return 0;
}

/*Typedefs Declared*/

/*Global Definitions*/
int retry_limit = 0;

INT Set_HTTP_Download_Url(char *pHttpUrl, char *pfilename) {
        int ret_stat = 0;
        char pGetHttpUrl[CM_HTTPURL_LEN] = {'0'};
        char pGetFilename[CM_FILENAME_LEN] = {'0'};
        errno_t rc = -1;

        /*Set the HTTP download URL*/
#ifdef FEATURE_FWUPGRADE_MANAGER
        ret_stat = fwupgrade_hal_set_download_url(pHttpUrl, pfilename);
#else
	ret_stat = cm_hal_Set_HTTP_Download_Url(pHttpUrl, pfilename);
#endif
        if (ret_stat == RETURN_OK) {
                // zero out pGetHttpUril and pGetFilename before calling fwupgrade_hal_get_download_Url()
                rc = memset_s(pGetHttpUrl,sizeof(pGetHttpUrl), 0, sizeof(pGetHttpUrl));
                ERR_CHK(rc);
                rc = memset_s(pGetFilename,sizeof(pGetFilename), 0, sizeof(pGetFilename));
                ERR_CHK(rc);
                /*Get the status of the set above*/
#ifdef FEATURE_FWUPGRADE_MANAGER
                ret_stat = fwupgrade_hal_get_download_url(pGetHttpUrl, pGetFilename);
#else
                ret_stat = cm_hal_Get_HTTP_Download_Url(pGetHttpUrl, pGetFilename);
#endif
                if (ret_stat == RETURN_OK)
                    printf("\nXCONF BIN : URL has successfully been set\n");
                else
                    printf("\nXCONF BIN : HTTP url GET error");

        } else {
            printf("\nXCONF BIN : HTTP url SET error");
        }

        return ret_stat;
}

int filePresentCheck(const char *file_name)
{
        int ret = -1 ;
        if (file_name == NULL) {
                printf("filePresentCheck() Invalid Parameter\n");
                return ret;
        }
        struct stat sfile;
        memset(&sfile, '\0', sizeof(sfile));
        ret = stat(file_name, &sfile);
        printf("filePresentCheck() name:%s:ret:%d\n", file_name, ret);
        return ret;
}


int isStateRedSupported()
{
        int ret = -1;
        ret = filePresentCheck("/lib/rdk/stateRedRecovery.sh");
        if (ret == 0) {
                printf("isStateRedSupported(): Yes file present:%s\n","/lib/rdk/stateRedRecovery.sh");
                return 1;
        }
        printf("isStateRedSupported(): No Not prsent:%s\n", "/lib/rdk/stateRedRecovery.sh");
        return 0;
}


int isInStateRed()
{
        int ret = -1;
        int stateRed = 0;
        ret = isStateRedSupported();
        if (ret == 0) {
                printf("isInStateRed(): No ret:%d\n", stateRed);
                return stateRed;
        }
        ret = filePresentCheck("/tmp/stateRedEnabled");
        if (ret == 0) {
                printf("isInStateRed(): Yes Flag prsent:%s\n", "/tmp/stateRedEnabled");
                stateRed = 1;
        }
        printf("isInStateRed(): No Not prsent:%s\n", "/tmp/stateRedEnabled");
        return stateRed;
}

void checkAndEnterStateRed()
{
    int ret = -1;
    FILE *fp = NULL;
	char res[16];
	int curlret = 0;
    ret = isStateRedSupported();
    if (ret == 0) {
        return;
    }
    ret = isInStateRed();
    if (ret == 1) {
        printf("RED checkAndEnterStateRed: device state red recovery flag already set\n");
        return;
    }

    fp = fopen("/tmp/xconf/dload_status", "r");
    if(NULL != fp)
    {
        memset(res, 0, sizeof(res));
        fgets(res, sizeof(res)-1, fp);
        fclose(fp);
        curlret = atoi(res);
	if ((curlret == 35) || (curlret == 51) || (curlret == 53) || (curlret == 54) || (curlret == 58) || (curlret == 59) || (curlret == 60) || (curlret == 64) || (curlret == 66) || (curlret == 77) || (curlret == 80) || (curlret == 82) || (curlret == 83) || (curlret == 90) || (curlret == 91)) {
            printf("Curl SSL/TLS error %d. Set State Red Recovery Flag and Exit!!!",curlret);
            fp = fopen("/tmp/stateRedEnabled","w");
            if (fp != NULL) {
                fclose(fp);
            }
            exit(1);
        }
    }
	else
    {
        printf("curl_status : file open error!");
    }
}

INT HTTP_Download ()
{   
    int ret_stat;
    int http_dl_status=0;
    int retry_http_status=1;
    int retry_http_dl=1;
    FILE *log_wget = NULL;
#if defined (FEATURE_RDKB_LED_MANAGER_CAPTIVE_PORTAL)
    char redirFlag[10]={0};
    char captivePortalEnable[10]={0};
    bool led_disable = false;
    FILE *fp = fopen(HTTP_LED_FLASH_DISABLE_FLAG, "r");
    if(fp != NULL)
            led_disable = true;
#endif 

    /* interface=0 for wan0, interface=1 for erouter0 */
    unsigned int interface=1;

#ifdef FEATURE_RDKB_LED_MANAGER
    sysevent_led_fd =  sysevent_open(SYS_IP_ADDR, SE_SERVER_WELL_KNOWN_PORT, SE_VERSION, "xconf_upgrade", &sysevent_led_token);
#endif
    /*Set the download interface*/
    printf("\nXCONF BIN : Setting download interface to %d",interface);
#ifdef FEATURE_FWUPGRADE_MANAGER
    fwupgrade_hal_set_download_interface(interface);
#else
    cm_hal_Set_HTTP_Download_Interface(interface);
#endif
    while((retry_limit < RETRY_HTTP_DOWNLOAD_LIMIT) && (retry_http_dl==1))
    {
#if defined (FEATURE_RDKB_LED_MANAGER)
#if defined (FEATURE_RDKB_LED_MANAGER_CAPTIVE_PORTAL)
	    if (!led_disable) {
		    printf("Led Flashing Not Disabled \n");
		    if (sysevent_led_fd != -1) {
			    sysevent_set(sysevent_led_fd, sysevent_led_token, SYSEVENT_LED_STATE, FW_DOWNLOAD_START_EVENT, 0);
		    }
	    }
#else
            if(sysevent_led_fd != -1)
            {
                sysevent_set(sysevent_led_fd, sysevent_led_token, SYSEVENT_LED_STATE, FW_DOWNLOAD_START_EVENT, 0);
            }
#endif
#endif
#ifdef FEATURE_FWUPGRADE_MANAGER
            ret_stat = fwupgrade_hal_download ();
#else
            ret_stat = cm_hal_HTTP_Download ();
#endif
            /*If the HTTP download started succesfully*/
            if(ret_stat == RETURN_OK)
            {
                printf("\nXCONF BIN : HTTP download started\n");
                /*
                 * Continue to get the download status if the retry_http_status flag is set,
                 * implying the image is being downloaded and disable the retry_http_dl flag.
                 *
                 * Stop getting the image download status, if the download was succesfull or
                 * if an error was received, in which case retry the http download
                 */
                
                /*
                 * Sleeping since the status returned is 
                 * 500 on immediate status query
                 */
                printf("\nXCONF BIN : Sleeping to prevent 500 error"); 
                sleep(10);

                
                /* Check if the /tmp/wget.log file was created, if not wait an adidtional time
                */
                log_wget= fopen("/tmp/wget.log", "r");

                if (log_wget == NULL) 
                {
                    printf("\n XCONF BIN : /tmp/wget.log doesn't exist. Sleeping an additional 10 seconds");
                    sleep(10);
                }
                else 
                {
                    fclose(log_wget);
                    printf("XCONF BIN : /tmp/wget.log created . Continue ...\n");
                }


                while(retry_http_status ==1)
                {    
                    /*Get the download status till SUCCESS*/
#ifdef FEATURE_FWUPGRADE_MANAGER
                    http_dl_status = fwupgrade_hal_get_download_status();
#else
                    http_dl_status = cm_hal_Get_HTTP_Download_Status();
#endif
                    /*Download completed succesfully*/
                    if(http_dl_status ==200)
                    {
                        printf("\nXCONF BIN : HTTP download COMPLETED with status : %d\n",http_dl_status);
                        retry_http_status=0;
                        retry_http_dl=0;

                        //printf("\nBIN : retry_http_status : %d",retry_http_status);
                        //printf("\nBIN : retry_dl_status : %d",retry_http_dl);
#if defined (FEATURE_RDKB_LED_MANAGER)
#if defined (FEATURE_RDKB_LED_MANAGER_CAPTIVE_PORTAL)
            if (!led_disable) {
            printf("Led Flashing Not Disabled \n");
            if (!syscfg_get(NULL, "redirection_flag", redirFlag, sizeof(redirFlag)) &&
               !syscfg_get(NULL, "CaptivePortal_Enable", captivePortalEnable, sizeof(captivePortalEnable))) {
              if (!strncmp(redirFlag, "true", 4) && !strncmp(captivePortalEnable, "true", 4)) {
                  if (sysevent_led_fd != -1) {
                      sysevent_set(sysevent_led_fd, sysevent_led_token, SYSEVENT_LED_STATE, FW_DOWNLOAD_STOP_CAPTIVEMODE, 0);
                  }
              } else {
                  if (sysevent_led_fd != -1) {
                      sysevent_set(sysevent_led_fd, sysevent_led_token, SYSEVENT_LED_STATE, FW_DOWNLOAD_STOP, 0);
                  }
              }
            }
            } 
#else
	    if(sysevent_led_fd != -1)
	    {
		    sysevent_set(sysevent_led_fd, sysevent_led_token, SYSEVENT_LED_STATE, FW_UPDATE_COMPLETE_EVENT, 0);
	    }
#endif
#endif
#if defined(MODEM_ONLY_SUPPORT) || defined(_XB10_PRODUCT_REQ_)
                        {
                             LONG value = 0;
                             int reboot_status; 
                             int ret = RETURN_ERR;
			     bool RFSignalStatus = false;
                             
			     ret = docsis_IsEnergyDetected(&RFSignalStatus);

			     if ((ret == RETURN_OK) && (RFSignalStatus == true))
                             {
                                  reboot_status = cm_hal_Reboot_Ready(&value);

                                  if(reboot_status == RETURN_OK && value == 1)
                                  {
                                      printf("\nXCONF BIN : HTTP image download and flashing COMPLETED Setting Online LED to solid WHITE");
                                      v_secure_system("/usr/bin/SetLED 0 0 ");
                                  }
		            }		 
                        }
#endif
                    }
                    
                    else if (http_dl_status == 0)
                    {

                        printf("\nXCONF BIN : HTTP download is waiting to start with status : %d",http_dl_status);
                        
                        retry_http_dl=0;    
                        
                        sleep(5);
                        
                    }        
                    else if((http_dl_status>0)&&(http_dl_status<=100))
                    {   
                        //This is already set to 1
                        //retry_http_status=1;
                        retry_http_dl=0;

                        printf("\nXCONF BIN : HTTP download in PROGRESS with status :  %d%%",http_dl_status);
                        
                        sleep(2);
                    }
                

                    /* If an error is received, fail the HTTP download
                     * It will be retried in the next window
                     */
		    else if (http_dl_status > 400)
		    {
			    retry_http_dl=0;
			    retry_http_status=0;
		    }
                            
                }
                          
            }//If condition

            /* If the HTTP download status returned with an error, 
             * a download was already in progress, 
             * retry after sleep
             */
            else
            {
                printf("\nXCONF BIN : HTTP Download not started. Retrying download after some time"); 

                /*This is to indicate that the actual download never started
                since a secondary download never ended or there was an error*/
                
                http_dl_status =-1;

                retry_http_dl=1;
                retry_limit++;
                //check and enter state red if curl code matches. if already in state red do nothing.
                checkAndEnterStateRed();
                sleep(10);
            }

    }//While condition 

    /*
     * The return status can either be
     * 200  : The download was succesful
     * >400 : An error was encountered . Retry in the next HTTP download window.
     * -1   : The actual http dl never started due to a secondary dl in progress or the primary dl not starting
     */
    if ((http_dl_status > 400) || (http_dl_status == -1))
    {
#if defined (FEATURE_RDKB_LED_MANAGER)
            /* Either image download or flashing failed. set previous state */
#if defined (FEATURE_RDKB_LED_MANAGER_CAPTIVE_PORTAL)
            if (!led_disable) {
            printf("Led Flashing Not Disabled \n");
            if (!syscfg_get(NULL, "redirection_flag", redirFlag, sizeof(redirFlag)) &&
               !syscfg_get(NULL, "CaptivePortal_Enable", captivePortalEnable, sizeof(captivePortalEnable))) {
              if (!strncmp(redirFlag, "true", 4) && !strncmp(captivePortalEnable, "true", 4)) {
                  if (sysevent_led_fd != -1) {
                      sysevent_set(sysevent_led_fd, sysevent_led_token, SYSEVENT_LED_STATE, FW_DOWNLOAD_STOP_CAPTIVEMODE, 0);
                  }
              } else {
                  if (sysevent_led_fd != -1) {
                      sysevent_set(sysevent_led_fd, sysevent_led_token, SYSEVENT_LED_STATE, FW_DOWNLOAD_STOP, 0);
                  }
              }
            }
            } 
#else
            if(sysevent_led_fd != -1)
            {
                sysevent_set(sysevent_led_fd, sysevent_led_token, SYSEVENT_LED_STATE, FW_UPDATE_STOP_EVENT, 0);
            }
#endif
#endif
	    printf("\nXCONF BIN : HTTP DOWNLOAD ERROR with status : %d. Exiting.",http_dl_status);
            //check and enter state red if curl code matches. if already in state red do nothing.
	    #if defined (INTEL_PUMA7)
                v_secure_system("/usr/bin/getArmCurlCode.sh");
            #endif
            checkAndEnterStateRed();
	    if(http_dl_status == 500)
	    {
		    //"header": "SYS_INFO_FW_Dwld_500Error", "content": "HTTP download ERROR with status : 500", "type": "ArmConsolelog.txt.0"
		    t2_event_d("SYS_INFO_FW_Dwld_500Error",1);
	    }
	    t2_event_d("XCONF_Dwnld_error",1);
    }

#ifdef FEATURE_RDKB_LED_MANAGER
#if defined (FEATURE_RDKB_LED_MANAGER_CAPTIVE_PORTAL)
    if (led_disable == true)
	    fclose(fp);
#endif
    if (0 <= sysevent_led_fd)
    {
        sysevent_close(sysevent_led_fd, sysevent_led_token);
    }
#endif

    return http_dl_status;  
    
}
	

INT Reboot_Ready(LONG *pValue)
{
    int reboot_ready_status;
#if defined(_ENABLE_EPON_SUPPORT_)
    reboot_ready_status = dpoe_hal_Reboot_Ready(pValue);
#else
#ifdef FEATURE_FWUPGRADE_MANAGER
    reboot_ready_status = fwupgrade_hal_reboot_ready(pValue);
#else
    reboot_ready_status = cm_hal_Reboot_Ready(pValue);
#endif
#endif
    return reboot_ready_status;    
}

INT HTTP_Download_Reboot_Now ()
{
int http_reboot_stat; 
#ifdef FEATURE_FWUPGRADE_MANAGER
http_reboot_stat= fwupgrade_hal_download_reboot_now();
#else
http_reboot_stat= cm_hal_HTTP_Download_Reboot_Now();
#endif
if(http_reboot_stat == RETURN_OK)
    printf("\nXCONF BIN : Rebooting the device now!\n");

else
    printf("\nXCONF BIN : Reboot in progress. ERROR!\n");

return  http_reboot_stat;       
}

INT HTTP_LED_Flash ( int LEDFlashState )
{
	int http_led_flash_stat = -1; 

#ifdef HTTP_LED_FLASH_FEATURE
#ifdef FEATURE_FWUPGRADE_MANAGER
	http_led_flash_stat= fwupgrade_hal_led_flash( LEDFlashState );
#else
        http_led_flash_stat= cm_hal_HTTP_LED_Flash( LEDFlashState );
#endif
	if(http_led_flash_stat == RETURN_OK)
	{
	    printf("\nXCONF BIN : setting LED flashing completed! %d\n", LEDFlashState);
	}
	else
	{
	    printf("\nXCONF BIN : setting LED flashing completed. ERROR!\n");
	}
#else
		printf("\nXCONF BIN : Setting LED flashing not supported. ERROR!\n");
#endif /* HTTP_LED_FLASH_FEATURE */

	return  http_led_flash_stat;       
}


int can_proceed_fw_download(void)
{
    char url[1024] = {0};
    char fname[256] = {0};
    char buf[64] = {0};
    char line[256] = {0};

    uint64_t fw_kb = 0;
    uint64_t avail_kb = 0;
    uint64_t rsrv_mb = 0, rsrv_kb = 0;
    int imgp_pct = 0;

    /* 1) Fetch URL and filename */
    if (cm_hal_Get_HTTP_Download_Url(url, fname) != 0 || url[0] == '\0') {
        printf("[FWCHK] Failed to get download URL/filename\n");
        return 0;
    }
    printf("[FWCHK] URL: %s\n", url);

    /* 2) Fetch Content-Length using curl CLI via popen (NO libcurl needed) */
    {
        char cmd[1500];
        snprintf(cmd, sizeof(cmd),
                 "curl -sI '%s' | grep -i Content-Length | awk '{print $2}'",
                 url);

        FILE *fp = popen(cmd, "r");
        if (!fp) {
            printf("[FWCHK] popen() failed for curl\n");
            return 0;
        }

        if (fgets(line, sizeof(line), fp) == NULL) {
            printf("[FWCHK] Content-Length not found\n");
            pclose(fp);
            return 0;
        }
        pclose(fp);

        uint64_t bytes = strtoull(line, NULL, 10);
        if (bytes == 0) {
            printf("[FWCHK] Invalid Content-Length\n");
            return 0;
        }

        fw_kb = (bytes + 1023ULL) / 1024ULL;
        printf("[FWCHK] Firmware size: %" PRIu64 " kB\n", fw_kb);
    }

    /* 3) Read MemAvailable (kB) */
    {
        FILE *fp = fopen("/proc/meminfo", "r");
        if (!fp) {
            printf("[FWCHK] Cannot read /proc/meminfo\n");
            return 0;
        }

        while (fgets(line, sizeof(line), fp)) {
            if (strncmp(line, "MemAvailable:", 13) == 0) {
                char *p = line + 13;
                while (*p && !isdigit((unsigned char)*p)) ++p;
                avail_kb = strtoull(p, NULL, 10);
                break;
            }
        }
        fclose(fp);

        if (avail_kb == 0) {
            printf("[FWCHK] MemAvailable not found\n");
            return 0;
        }
        printf("[FWCHK] MemAvailable: %" PRIu64 " kB\n", avail_kb);
    }

    /* 4) syscfg variables EXACTLY as you wanted */
    syscfg_get(NULL, "FwDwld_AvlMem_RsrvThreshold", buf, sizeof(buf));
    rsrv_mb = atoi(buf);
    rsrv_kb = rsrv_mb * 1024ULL;
    printf("[FWCHK] ReserveThreshold: %llu MB\n", (unsigned long long)rsrv_mb);

    syscfg_get(NULL, "FwDwld_ImageProcMemPercent", buf, sizeof(buf));
    imgp_pct = atoi(buf);
    if (imgp_pct < 0) imgp_pct = 0;
    printf("[FWCHK] ImageProcPercent: %d %%\n", imgp_pct);

    /* 5) Required Memory calculation */
    uint64_t img_proc_kb = (fw_kb * imgp_pct + 99ULL) / 100ULL;
    uint64_t required_kb = fw_kb + rsrv_kb + img_proc_kb;

    printf("[FWCHK] Required Memory: %" PRIu64 " kB\n", required_kb);

    /* 6) Verdict */
    if (avail_kb >= required_kb) {
        printf("[FWCHK] Verdict: PROCEED\n");
        return 1;
    }

    printf("[FWCHK] Verdict: BLOCK\n");
    return 0;
}

int main(int argc,char *argv[])
{
    char *pfilename = NULL;
    char pHttpUrl[CM_HTTPURL_LEN] = {'0'};

    LONG value = 0;
    int ret_code = 0;
    int http_status,reboot_status;
    int reset_device;
    errno_t rc = -1;
    int ind = -1;
    enum ArgumentType_Xconf_e   type;
    char buf[8]={'\0'};
#if defined (_COSA_BCM_ARM_)
    int dl_status = 0;
#endif

    t2_init("ccsp-xconf");


        if (argv[1] == NULL)
        {
                printf("NULL arguments, returning\n");
                ret_code = 1;
                return ret_code;
        }

    if(get_argument_type_from_argv(argv[1], &type)){
    if(type == SET_HTTP_URL)
    {
            /*
             * End users of XconfHttpDl should not be impacted due to update in HAL api changes
             * New HAL apis using CURL needs exact location. Eg.:
             *      XconfHttpDl set_http_url http://download.server/image.bin image.bin
             */

             if (((argv[2]) != NULL) && ((argv[3]) != NULL)) {

                  pfilename = argv[3];

                  if ((argv[4]) != NULL) {
                      rc = strcmp_s("complete_url",strlen("complete_url"),argv[4],&ind);
                      ERR_CHK(rc);
                      if((ind == 0) && (rc == EOK)) {
                          // Exact download location passed by caller.
                          rc = strcpy_s(pHttpUrl,sizeof(pHttpUrl), argv[2]);
                          ERR_CHK(rc);
                          ret_code = Set_HTTP_Download_Url(pHttpUrl, pfilename);
                       } else if((strstr(argv[4], "--cert")) && ((argv[2]) != NULL)) {
                            rc = sprintf_s(pHttpUrl, sizeof(pHttpUrl), "%s '%s/%s'", argv[4], argv[2], pfilename);
                            ERR_CHK(rc);
                            ret_code = Set_HTTP_Download_Url(pHttpUrl, pfilename);
                       } else {
                            printf("XCONF BIN : Unknown 3rd argument %s . Failed to complete set_http_url operation.\n", argv[4]);
                       }
                  } else {
                      // TBD - Evaluate impact on all other platforms which doesn't have changes in oem HAL api
                      // Form complete download URL from args passed by caller including the quotes
                      // "'" + pHttpUrl + "/" + "pfilename" + "'"

                      syscfg_get(NULL, "SWDLDirectEnable", buf, sizeof(buf));
                      if (strcmp(buf, "true") == 0) {
                        rc = sprintf_s(pHttpUrl, sizeof(pHttpUrl), "'%s'", argv[2]);
                        if(rc < EOK ) {
                          ERR_CHK(rc);
                        }
                      }
                      else {
                        rc = sprintf_s(pHttpUrl, sizeof(pHttpUrl), "'%s/%s'", argv[2], pfilename);
                        if(rc < EOK ) {
                          ERR_CHK(rc);
                        }
                      }
                      ret_code = Set_HTTP_Download_Url(pHttpUrl, pfilename);
                  }

            }

    }
    else if (type == HTTP_DOWNLOAD)
    {
        if(can_proceed_fw_download()){
            printf("We can proceed with fw_download\n");
        }
        http_status = HTTP_Download();

        // The return code is after RETRY_HTTP_DOWNLOAD_LIMIT has been reached
        // For 200, return SUCCESS, else FAILURE and retry in the next window
        if(http_status == 200)
            ret_code = 0;

        else
            ret_code = 1;

    }

    else if (type == HTTP_REBOOT_STATUS)
    {

        reboot_status = Reboot_Ready(&value);
        printf("XCONF BIN : Reboot_Ready status %ld \n", value);
        if(reboot_status == RETURN_OK && value == 1)
            ret_code = 0;

        else
            ret_code= 1;
    }

    else if(type == HTTP_REBOOT)
    {
        reset_device = HTTP_Download_Reboot_Now();

            if(reset_device == RETURN_OK)
                ret_code = 0;

            else
                ret_code= 1;
    }
    else if(type == HTTP_FLASH_LED)
    {
        if( argv[2] != NULL )
        {
            reset_device = HTTP_LED_Flash( atoi(argv[2]) );
            
                if(reset_device == RETURN_OK)
                    ret_code = 0;
                else
                    ret_code= 1;
        }
    }
    else if(type == UPGRADE_FACTORYRESET)
    {
        if (((argv[2]) != NULL) && ((argv[3]) != NULL))
        {
            pfilename = argv[3];
            rc = strcpy_s(pHttpUrl,sizeof(pHttpUrl), argv[2]);
            ERR_CHK(rc);
        }
        printf("XCONF BIN : upgrade_factoryreset calling cm_hal_FWupdateAndFactoryReset \n" );
        printf("XCONF BIN : URL: %s FileName %s \n", pHttpUrl, pfilename );
        reset_device = cm_hal_FWupdateAndFactoryReset( pHttpUrl, pfilename );
        printf("XCONF BIN : hal return value %d\n", reset_device);
        if(reset_device == RETURN_OK)
        {
            ret_code = 0;
#if defined (_COSA_BCM_ARM_)
            while(1)
            {
                dl_status = cm_hal_Get_HTTP_Download_Status();

                if(dl_status >= 0 && dl_status <= 100)
                    sleep(2);
                else if(dl_status == 200)
                    sleep(10);
                else if(dl_status >= 400)
                {
                    printf(" FW DL is failed with status %d \n", dl_status);
                    ret_code= 1;
                    break;
                }
            }
#endif
        }
        else
        {
            ret_code= 1;
        }

     }
    }
    return ret_code;
}
