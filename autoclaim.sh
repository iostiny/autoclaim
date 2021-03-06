#!/usr/bin/env bash
# I recommend to use this script outside your BP node. If so I fully recommend
# to do it over a secured connection since you have to send your wallet's pass
# to your BP (or any other BP) node to be processed. You can install a reverse
# proxy like nginx (check:). Make sure you have a local  wallet defined with your
# BP key imported.
# This script was inspired by the one created by AnsenYu
# https://github.com/AnsenYu/ENUAvengers/tree/master/scripts/bpclaim
# Thanks very much for Dragos Vlaicu, his script helps to finish this job.
# iostiny - 2018/09/18 - ENU BP - iostinylenux
# Version: 1.0

PATH=/usr/local/sbin:/usr/local/bin:/usr/local/enumivo/bin/:/usr/sbin:/usr/bin:/sbin:/bin

# lock the timezone to UTC to match the database
export TZ=Etc/UTC

# IF you are not using the default wallet you can mention it here
wallet='YourMaimWalletName'
walletForDistribution='YourSecondWalletName'
# one day in seconds
day=86400

# enucli wallet shortcut if the binaries were not installed after the build
# followed by the BP http(s) server
enucli='enucli -u https://api.enumivo.com'
# The ammount of coins you want to leave in your wallet. The rest will be staked
# it should be an integer from 0 to whatever you want
# WARNING: The rest of the coins will be staked
keep=0
passwd=$1
BP=$2
passwdDummy=$3

# Telegram configuration
# telegram bot token ID
bot_token='bot_token'
# private chat IDs
chat_ids=("chat_id_a" "chat_id_b" "chat_id_c" "chat_id_...")
# enable/disable Telegram chat. If you set the variable to 1 will be anabled.
# anything else meanse disabled. By default is enabled.
telechat=1

# PushBullet configuration
push_token='your_push_token'
# enable/disable PushBullet notifications. If you set the variable to 1 will be anabled.
# anything else meanse disabled. By default is enabled.
pushbullet=1

#script working directory
script="$(readlink -f $0)"
wd="$(dirname ${script})"
# log file
logfile="${wd}/enuclaim.log"

function last() {
  now_epoch=$(date +"%s")
  time_diff=$((${now_epoch}-$1))
  echo ${time_diff}
}

TS="$(date '+[%Y-%m-%d %H:%M:%S]')"
function logall() {
  tolog=$@
  echo "${TS} ${tolog}" | tee -a ${logfile}
  if [[ ${telechat} -eq 1 ]]; then
    for i in "${chat_ids[@]}"
    do
      curl -s https://api.telegram.org/bot${bot_token}/sendMessage -d chat_id="${i}" -d text="${TS} ${tolog}" > /dev/null
    done
  fi
  if [[ ${pushbullet} -eq 1 ]]; then
    curl -u ${push_token}: https://api.pushbullet.com/v2/pushes -d type=note -d title="Enumivo AutoclaimScript" -d body="${TS} ${tolog}"
  fi
}

# Check if the there needed variables were given
# expected: wallet's password followed by BPUsername
if [ $# -ne 3 ]; then
  logall "You're missing a few arguments"
  logall "Please use the script like this: $0 BPWalletPwd BPUsername DummyWalletPwd"
  exit 1
fi

# Validate the password format
if [[ ! $passwd =~ ^PW5.* ]]; then
  logall "Invalid wallet password. Exiting ..."
  exit 2
fi

# Check last claimed time
last_claim_time=$(${enucli} get table enumivo enumivo producers -l 10000 | grep -A 6 "${BP}" | awk -F '"' '$2 == "last_claim_time" {print $4}')
if [[ $? -ne 0 || ${last_claim_time} -eq 0 ]]; then
    logall "Invalid last claim time, claim manually to set a relevant time. Exiting ..."
    exit 3
fi
# calculate how much time it passed from last claim. if it's under a day we'll wait a bit more.
last_claimed=$((${last_claim_time} / 1000000))



stotal=0
st=1
while [[ ${st} -ne 0 ]]; do
  if [[ $(last ${last_claimed}) -lt ${day} ]]; then
    sleep 2
  else
    # unlock the wallet
    ${enucli} wallet unlock -n ${wallet} --password ${passwd}
    # Check if the wallet gets unlocked successfully
    if [[ $? -ne 0 ]]; then
      logall "Unable to unlock your wallet with given password. Exiting ..."
      exit 4
    fi

    # try to claim your stakes
    claim=$(${enucli} system claimrewards ${BP} 2>&1)
    if [[ $? -ne 0 ]]; then
      ${enucli} wallet lock_all
      logall "Error while claiming. Check log file and do it manually if you can. Exiting ..."
      echo "${claim}" >> ${logfile}
      exit 5
    else
      logall "Claimed successfully"
      # Get the coins out of your wallet. WARNING: It will use all your coins from
      # your wallet. IF you want to keep some aside please configure the variable keep

      # check if bc is instaled.
      instbc=0
      # split wallet's coins in two to stake them evenly. It will get rounded down
      which bc >/dev/null
      if [[ $? -ne 0 ]]; then
        logall "bc is not installed. I will try to install it for you. Root access is needed."
        sudo apt-get update
        sudo apt-get install bc -y
        if [[ $? -ne 0 ]]; then
          logall " Unable to install bc. I'm unable to split your coins in half for staking. Please stake them manually."
          instbc=1
        fi
      fi

      if [[ ${instbc} -eq 0 ]]; then
        bpay=$(echo "${claim}" | grep "${BP} <= enu.token::transfer" | awk -F '"' '$4 == "enu.blockpay" {print substr($12,1, length($12)-4)}')
        if [[ -z ${bpay} ]]; then
          bpay=0
        fi
        vpay=$(echo "${claim}" | grep "${BP} <= enu.token::transfer" | awk -F '"' '$4 == "enu.votepay" {print substr($12,1, length($12)-4)}')
        if [[ -z ${vpay} ]]; then
          vpay=0
        fi

        stotal=$(bc <<< "${bpay} + ${vpay}")
        #walletcoins=$(${enucli} get currency balance enu.token ${BP} | awk '{print $1}')
        logall "Today you claimed as blockproducer [${bpay}] and based on votes [${vpay}] in total: [${stotal}]"

        tostake=$(bc <<< "(${stotal} - ${keep}) / 2")
        if [[ ${tostake} -gt 0 ]]; then
          # Stake your coins
          ${enucli} system delegatebw ${BP} ${BP} "${tostake} ENU" "${tostake} ENU"
          logall "${tostake} ENU were staked for CPU and the same for Network"
        fi
      fi
      # Lock your wallet.
      ${enucli} wallet lock -n iostinylenux
      if [[ $? -eq 0 ]]; then
        logall "iostinylenux wallet is locked now"
      fi
    fi
    st=0
  fi
done

# Unlock an other wallet
${enucli} wallet unlock -n ${walletForDistribution} --password ${passwdDummy}
# Check if the wallet gets unlocked successfully
if [[ $? -ne 0 ]]; then
  logall "Unable to unlock your ${walletForDistribution} wallet with given password. Exiting ..."
  ${enucli} wallet lock_all
  exit 4
fi

# Check if total coin is bigger than zero that claimed.
if [[ $(echo "${stotal} <= 0" | bc) = 1 ]]; then
  logall "Claim rewards result is ZERO, no distribution this time"
  ${enucli} wallet lock_all
  exit 6
fi

# Get total_voting_weight
iostinylenux_total_votes=$(${enucli} get table enumivo enumivo producers -l 10000 | grep -A 2 "${BP}" | awk -F '"' '$2 == "total_votes" {print substr($4,1, length($4)-18)}')
if [[ -z ${iostinylenux_total_votes} ]]; then
  logall "Get iostinylenux_total_votes of iostinylenux failed, exit..."
  ${enucli} wallet lock_all
  exit 7
fi

# Get each's voting_weight and distribute
array=(accountNameA accountNameB ...)
distribution_ratio=0.6
for distributionName in ${array[@]}
do
  #Get last_vote_weight
  each_last_vote_weight=$(${enucli} get account "${distributionName}" -j | grep last_vote_weight | awk -F '"' '$2 == "last_vote_weight" {print substr($4,1, length($4)-18)}')
  if [[ -z ${each_last_vote_weight} ]]; then
    logall "Get each_last_vote_weight of '${distributionName}' failed, exit..."
    ${enucli} wallet lock_all
    exit 8
  fi

  #Calculate distribution number
  distribution_number=$(echo "scale=4; ${stotal} * ${distribution_ratio} * ${each_last_vote_weight} / ${iostinylenux_total_votes}" | bc)
  transfer_info=$(printf "%.4f ENU" ${distribution_number})
  if [ $(echo "${distribution_number} > 0" | bc) = 1 ]; then
    # distribute it
    ${enucli} transfer ${walletForDistribution} ${distributionName} "${transfer_info}" "${TS} distribution"
    logall "[${transfer_info}] were distribute to ${distributionName}"
  fi
done

# Lock your wallet.
${enucli} wallet lock_all
if [[ $? -eq 0 ]]; then
  logall "All wallets are locked now"
fi

