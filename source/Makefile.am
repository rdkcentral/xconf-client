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

bin_PROGRAMS = XconfHttpDl
AM_CPPFLAGS = -I$(top_srcdir)/hal/include
AM_CFLAGS = $(AM_CPPFLAGS)
AM_LDFLAGS = -lccsp_common
AM_LDFLAGS += -lcm_mgnt -lsysevent -lsyscfg
XconfHttpDl_SOURCES = cm_http_dl.c

