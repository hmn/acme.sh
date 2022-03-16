#!/bin/bash

# Script to remove certificate from a Citrix VPX instance via deploy
#
# The following variables exported from environment will be used.
# If not set then values previously saved in domain.conf file are used.
#
# All the variables are required
#
# export CITRIX_VPX_HOSTNAME="vpx.example.com"
# export CITRIX_VPX_USERNAME="nsroot"
# export CITRIX_VPX_PASSWORD="nsroot"
#
# export HTTPS_INSECURE="true" can be used if VPX instance does not use valid ssl certs yet
#
# Dependencies:
# -------------
# - jq and curl

citrix_vpx_remove_deploy() {
  _cdomain="$1"
  _ckey="$2"
  _ccert="$3"
  _cca="$4"
  _cfullchain="$5"

  _debug _cdomain "$_cdomain"
  _debug _ckey "$_ckey"
  _debug _ccert "$_ccert"
  _debug _cca "$_cca"
  _debug _cfullchain "$_cfullchain"

  # Get Hostname, Username and Password for Citrix VPX
  _getdeployconf CITRIX_VPX_HOSTNAME
  _getdeployconf CITRIX_VPX_USERNAME
  _getdeployconf CITRIX_VPX_PASSWORD

  if [ -z "$CITRIX_VPX_HOSTNAME" ]; then
    _err "CITRIX_VPX_HOSTNAME not defined."
    return 1
  fi
  if [ -z "$CITRIX_VPX_USERNAME" ]; then
    _err "CITRIX_VPX_USERNAME not defined."
    return 1
  fi
  if [ -z "$CITRIX_VPX_PASSWORD" ]; then
    _err "CITRIX_VPX_PASSWORD not defined."
    return 1
  fi

  _debug2 CITRIX_VPX_HOSTNAME "$CITRIX_VPX_HOSTNAME"
  _debug2 CITRIX_VPX_USERNAME "$CITRIX_VPX_USERNAME"
  _secure_debug2 CITRIX_VPX_PASSWORD "$CITRIX_VPX_PASSWORD"

  # get domain list to check login details
  _info "Test Citrix VPX login credentials"
  _citrix_vpx_rest GET "/config/systemfile" "?args=filelocation:%2Fnsconfig%2Fssl" "false" "\"errorcode\": 0" || return $?

  # login seems to work so we can save config
  _savedeployconf CITRIX_VPX_HOSTNAME "$CITRIX_VPX_HOSTNAME"
  _savedeployconf CITRIX_VPX_USERNAME "$CITRIX_VPX_USERNAME"
  _savedeployconf CITRIX_VPX_PASSWORD "$CITRIX_VPX_PASSWORD"

  # configure certificate names and prepare base64 encoded certificates
  _name="le-${_cdomain}"

  # cleanup certs on citrix vpx

  _info "Lookup certificate in Citrix VPX"
  _citrix_vpx_rest GET "/config/sslcertkey/${_name}" "" "false" "\"errorcode\": 0" || return $?
  if [ "$_ret" == "0" ]; then
    _info "Certificate $_name found in Citrix VPX"  
    _details=$(echo "$_response" | jq '.sslcertkey')
    _info "$_details"
    _found=1
  else
    _info "Certificate $_name not found in Citrix VPX"
    _found=0
  fi

  if [ "$_found" == "1" ]; then
    _info "Unlink CA certificate in Citrix VPX"
    _request='{
      "sslcertkey": {
        "certkey": "'$_name'"
      }
    }'
    _citrix_vpx_rest POST "/config/sslcertkey?action=unlink" "$_request" "" "SKIP" || return $?
    _info "Certificate $_name unlinked in Citrix VPX"


    _info "Delete certificate in Citrix VPX"
    _citrix_vpx_rest DELETE "/config/sslcertkey/$_name" "" "" "\"errorcode\": 0" || return $?
    _info "Certificate $_name deleted in Citrix VPX"
  fi


  _info "Lookup certificate files on Citrix VPX"
  _citrix_vpx_rest GET "/config/systemfile" "?args=filelocation:%2Fnsconfig%2Fssl" "" "\"errorcode\": 0" "application/vnd.com.citrix.netscaler.systemfile+json" || return $?
  _info "Certificate files starting with name $_name found in Citrix VPX"  
  _details=$(echo "$_response" | jq -r '.systemfile[].filename | select(. | startswith("'$_name'"))')
  if [ ! -z "$_details" ]; then
    for file in $_details; do
      _info "Delete certificate ${file} from Citrix VPX"
      _citrix_vpx_rest DELETE "/config/systemfile/${file}?args=filelocation:%2Fnsconfig%2Fssl" "" "" "\"errorcode\": 0" "application/vnd.com.citrix.netscaler.systemfile+json" || return $?
      _info "$file removed from Citrix VPX"
    done
  else
    _info "No certificate files found in Citrix VPX"
  fi


  _info "Certificate successfully removed"
  return 0
}

_citrix_vpx_rest() {
  method=$1 # Request method GET, POST, PUT, DELETE
  endpoint="$2" # nitro endpoint url
  data="$3" # request data or query params
  secure="$4" # handle data as secure when logging
  expect="$5" # response should contain this string
  contenttype="$6"

  if [ -z "$contenttype" ]; then
    contenttype="application/json"
  fi

  # configure auth headers for api calls
  export _H1="X-NITRO-USER: $CITRIX_VPX_USERNAME"
  export _H2="X-NITRO-PASS: $CITRIX_VPX_PASSWORD"
  export _H3="Content-Type: $contenttype"
  NITRO_BASE_URL="https://$CITRIX_VPX_HOSTNAME/nitro/v1"
  if [ "$secure" == "true" ]; then
    _secure_debug data "$data"
  else
    _debug data "$data"
  fi

  if [ "$method" != "GET" ]; then
    URL="${NITRO_BASE_URL}${endpoint}"
    _debug "$URL"
    response="$(_post "$data" "${URL}" "" "$method")"
  else
    URL="${NITRO_BASE_URL}${endpoint}${data}"
    _debug "$URL"
    response="$(_get "${URL}")"
  fi

  if [ "$?" != "0" ]; then
    _err "Request error code $_ret"
    _ret=1
    return 1
  fi
  _debug response "$response"
  if [ "$expect" != "SKIP" ]; then
    if _contains "$response" "$expect"; then
      _info "Response contains $expect"
    else
      _err "Response missing $expect"
      _err "$response"
      _ret=1
      return 1
    fi
  fi
  _ret=0
  _response="$response"
  return 0
}
