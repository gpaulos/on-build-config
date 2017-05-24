#!/bin/bash -ex
export VCOMPUTE=("${NODE_NAME}-Rinjin1","${NODE_NAME}-Rinjin2","${NODE_NAME}-Quanta")
export UCSPE=("${NODE_NAME}-UCSPE")
RUN_FIT_TEST="${RUN_FIT_TEST}"
if [ ! -z "${4}" ]; then
  RUN_FIT_TEST=$4
fi
RUN_CIT_TEST="${RUN_CIT_TEST}"
if [ ! -z "${5}" ]; then
  RUN_FIT_TEST=$5
fi
MODIFY_API_PACKAGE="${MODIFY_API_PACKAGE}"

cleanupVMs(){
    vagrantDestroy
    # Suspend any other running vagrant boxes
    vagrantSuspendAll

    # Delete any running VMs
    virtualBoxDestroyAll

    rm -rf "$HOME/VirtualBox VMs"
}

apiPackageModify() {
    pushd ${WORKSPACE}/build-deps/on-http/extra
    sed -i "s/.*git symbolic-ref.*/ continue/g" make-deb.sh
    sed -i "/build-package.bash/d" make-deb.sh
    sed -i "/GITCOMMITDATE/d" make-deb.sh
    sed -i "/mkdir/d" make-deb.sh
    bash make-deb.sh
    popd
    for package in ${API_PACKAGE_LIST}; do
      sudo pip uninstall -y ${package//./-} || true
      pushd ${WORKSPACE}/build-deps/on-http/$package
        fail=true
        while $fail; do
          python setup.py install
          if [ $? -eq 0 ];then
        	  fail=false
          fi
        done
      popd
    done
}

VCOMPUTE="${VCOMPUTE}"
if [ -z "${VCOMPUTE}" ]; then
  VCOMPUTE=("jvm-Quanta_T41-1" "jvm-vRinjin-1" "jvm-vRinjin-2")
fi

TEST_GROUP="${TEST_GROUP}"
if [ -z "${TEST_GROUP}" ]; then
   TEST_GROUP="smoke-tests"
fi

execWithTimeout() {
  set +e
  # $1 command to execute
  # $2 timeout
  # $3 retries on timeout
  if [ -z "${1}" ]; then
     echo "execWithTimeout() Command not specified"
     exit 2
  fi
  cmd="/bin/sh -c \"$1\""
  #timeout default to one minute
  timeout=90
  retry=3
  result=0
  if [ ! -z "${2}" ]; then
    timeout=$2
  fi
  if [ ! -z "${3}" ]; then
    retry=$3
  fi
  echo "execWithTimeout() retry count is $retry"
  echo "execWithTimeout() timeout is set to $timeout"
  i=1
  while [[ $i -le $retry ]]
  do
    expect -c "set timeout $timeout; spawn -noecho $cmd; expect timeout { exit 1 } eof { exit 0 }"
    result=$?
    echo "execWithTimeout() exit code $result"
    if [ $result = 0 ] ; then
       break
    fi
    ((i = i + 1))
  done
  if [ $result = 1 ] ; then
       echo "execWithTimeout() command timed out $retry times after $timeout seconds"
       exit 1
  fi
  set -e
}

ucsReset() {
  cd ${WORKSPACE}/build-config/deployment/
  if [ "${USE_VCOMPUTE}" != "false" ]; then
    for i in ${UCSPE[@]}; do
      ./vm_control.sh "${ESXI_HOST},${ESXI_USER},${ESXI_PASS},reset,1,${i}_*"
    done
  fi
}

nodesOff() {
  cd ${WORKSPACE}/build-config/deployment/
  if [ "${USE_VCOMPUTE}" != "false" ]; then
    for i in ${VCOMPUTE[@]}; do
      ./vm_control.sh "${ESXI_HOST},${ESXI_USER},${ESXI_PASS},power_off,1,${i}_*"
    done
  else
     ./telnet_sentry.exp ${SENTRY_HOST} ${SENTRY_USER} ${SENTRY_PASS} off ${OUTLET_NAME}
     sleep 5
  fi
}

nodesOn() {
  cd ${WORKSPACE}/build-config/deployment/
  if [ "${USE_VCOMPUTE}" != "false" ]; then
    for i in ${VCOMPUTE[@]}; do
      ./vm_control.sh "${ESXI_HOST},${ESXI_USER},${ESXI_PASS},power_on,1,${i}_*"
    done
  else
     ./telnet_sentry.exp ${SENTRY_HOST} ${SENTRY_USER} ${SENTRY_PASS} on ${OUTLET_NAME}
     sleep 5
  fi
}

nodesDelete() {
  cd ${WORKSPACE}/build-config/deployment/
  if [ "${USE_VCOMPUTE}" != "false" ]; then
    if [ ${OVA_POST_TEST} == "true" ]; then
      VCOMPUTE+=("${NODE_NAME}-ova-for-post-test")
    fi
    for i in ${VCOMPUTE[@]}; do
      ./vm_control.sh "${ESXI_HOST},${ESXI_USER},${ESXI_PASS},delete,1,${i}_*"
    done
  fi
}

nodesCreate() {
  cd ${WORKSPACE}/build-config/deployment/
  if [ "${USE_VCOMPUTE}" != "false" ]; then
    for i in {1..2}
    do
      execWithTimeout "ovftool --noSSLVerify --diskMode=${DISKMODE} --datastore=${DATASTORE}  --name='${NODE_NAME}-Rinjin${i}' --net:'${NIC}=${NODE_NAME}-switch' '${HOME}/isofarm/OVA/vRinjin-Haswell.ova'   vi://${ESXI_USER}:${ESXI_PASS}@${ESXI_HOST}"
    done
    execWithTimeout "ovftool  --noSSLVerify --diskMode=${DISKMODE} --datastore=${DATASTORE} --name='${NODE_NAME}-Quanta' --net:'${NIC}=${NODE_NAME}-switch' '${HOME}/isofarm/OVA/vQuanta-T41-Haswell.ova'   vi://${ESXI_USER}:${ESXI_PASS}@${ESXI_HOST}"
  else
    nodesOff
  fi
}

vagrantSuspendAll() {
 for box in `vagrant global-status --prune | awk '/running/{print $1}'`; do
     vagrant suspend ${box}
 done
}

CONFIG_PATH=${CONFIG_PATH-build-config/vagrant/config/mongo}
vagrantUp() {
  cd ${WORKSPACE}/RackHD/example
  cp -rf ${WORKSPACE}/build-config/vagrant/* .
  result=0
  for i in {1..2}
  do
      CONFIG_DIR=${CONFIG_PATH} WORKSPACE=${WORKSPACE} vagrant up --provision
      result=$?
      if [ $result -ne 0 ]; then
          echo "Vagrant up failed!! retry one more time"
          vagrant destroy -f
          #suspend all running instance
          vagrantSuspendAll
          #rmeove all VMs before retying
          rm -rf "$HOME/VirtualBox VMs"
          rm "$HOME/.config/VirtualBox/VirtualBox.xml"
      else
          echo "Vagrant up passed."
          break
      fi
  done
  if [ $result -ne 0 ]; then
      echo "Vagrant up failed."
      exit 1
  fi
}

vagrantDestroy() {
  cd ${WORKSPACE}/RackHD/example
  vagrant destroy -f
}

vagrantHalt() {
  cd ${WORKSPACE}/RackHD/example
  vagrant halt
}

virtualBoxDestroyAll() {
  set +e
  for uuid in `vboxmanage list vms | awk '{print $2}' | tr -d '{}'`; do
    echo "shutting down vm ${uuid}"
    vboxmanage controlvm ${uuid} poweroff
    echo "deleting vm ${uuid}"
    vboxmanage unregistervm ${uuid}
  done
  set -e
}

generateSolLog(){
  cd ${WORKSPACE}/RackHD/example
  vagrant ssh -c 'cd /home/vagrant/src/build-config/; \
        bash generate-sol-log.sh' > ${WORKSPACE}/sol.log &
}

generateSysLog(){
  cd ${WORKSPACE}/RackHD/example
  vagrant ssh -c 'dmesg > /home/vagrant/src/dmesg.log'
  vagrant ssh -c 'cp /var/log/syslog /home/vagrant/src/syslog.log'
}

setupVirtualEnv(){
  pushd ${WORKSPACE}/RackHD/test
  rm -rf .venv/on-build-config
  ./mkenv.sh on-build-config
  source myenv_on-build-config
  popd
  if [ "$MODIFY_API_PACKAGE" == true ] ; then
      apiPackageModify
  fi
}

BASE_REPO_URL="${BASE_REPO_URL}"
runTests() {
  set +e
  if [ "$RUN_FIT_TEST" == true ] ; then
     cd ${WORKSPACE}/RackHD/test
     #TODO Parameterize FIT args
     python run_tests.py -test deploy/rackhd_stack_init.py -stack vagrant  -port 9090 -xunit
     if [ $? -ne 0 ]; then
         echo "Test FIT failed running deploy/rackhd_stack_init.py"
         exit 1
     fi
     python run_tests.py ${TEST_GROUP} -stack vagrant -port 9090 -v 4 -xunit
     if [ $? -ne 0 ]; then
         echo "Test FIT failed running smoke test"
         exit 1
     fi
     mkdir -p ${WORKSPACE}/xunit-reports
     cp *.xml ${WORKSPACE}/xunit-reports
  fi
  if [ "$RUN_CIT_TEST" == true ] ; then
     read array<<<"${TEST_GROUP}"
     args=()
     group=" --group="
     for item in $array; do
        args+="${group}${item}"
     done
     cp -f ${WORKSPACE}/build-config/config.ini ${WORKSPACE}/RackHD/test/config
     cd ${WORKSPACE}/RackHD/test
     RACKHD_BASE_REPO_URL=${BASE_REPO_URL} RACKHD_TEST_LOGLVL=INFO \
     python run.py ${args} --with-xunit
     mkdir -p ${WORKSPACE}/xunit-reports
     cp *.xml ${WORKSPACE}/xunit-reports
  fi
  set -e
}

waitForAPI() {
  timeout=0
  maxto=60
  set +e
  url=http://localhost:9090/api/2.0/nodes
  while [ ${timeout} != ${maxto} ]; do
    wget --retry-connrefused --waitretry=1 --read-timeout=20 --timeout=15 -t 1 --continue ${url}
    if [ $? = 0 ]; then 
      break
    fi
    sleep 10
    timeout=`expr ${timeout} + 1`
  done
  set -e
  if [ ${timeout} == ${maxto} ]; then
    echo "Timed out waiting for RackHD API service (duration=`expr $maxto \* 10`s)."
    exit 1
  fi
}

######################################
#    OVA POST SMOKE TEST RELATED     #
######################################
portForwarding(){
    # forward ova to localhost
    # according to vagrant/mongo/config.json and cit/fit config
    socat TCP4-LISTEN:9091,forever,reuseaddr,fork TCP4:$1:5672 &
    socat TCP4-LISTEN:9090,forever,reuseaddr,fork TCP4:$1:8080 &
    socat TCP4-LISTEN:9092,forever,reuseaddr,fork TCP4:$1:9080 &
    socat TCP4-LISTEN:9093,forever,reuseaddr,fork TCP4:$1:8443 &
    socat TCP4-LISTEN:2222,forever,reuseaddr,fork TCP4:$1:22 &
    echo "Finished ova -> localhost port forwarding"
    echo "5672->9091"
    echo "8080->9090"
    echo "9080->9092"
    echo "8443->9093"
    echo "22->2222"
}

fetchOVALog(){
    ansible_workspace=${WORKSPACE}/build-config/jobs/build_ova/ansible
    # fetch rackhd log
    pushd $ansible_workspace
      echo "ova-post-test ansible_host=$OVA_INTERNAL_IP ansible_user=$OVA_USER ansible_ssh_pass=$OVA_PASSWORD ansible_become_pass=$OVA_PASSWORD" > hosts
      ansible-playbook -i hosts main.yml --tags "after-test"
      mkdir -p ${WORKSPACE}/build-deps
      for log in `ls *.log | xargs` ; do
        cp $log ${WORKSPACE}/build-deps
      done
    popd
}

######################################
#  OVA POST SMOKE TEST RELATED END   #
######################################

if [ "$RUN_CIT_TEST" == true ] || [ "$RUN_FIT_TEST" == true ] ; then
  if [ "$TEST_TYPE" == "ova" ]; then
    # based on the assumption that in the same folder, the VMs has been exist normally. so don't destroy VM here.
    
    nodesCreate
    
    # Prepare RackHD
    # Forward local host port to ova
    portForwarding ${OVA_INTERNAL_IP}

    # We setup the virtual-environment here, since once we
    # call "nodesOn", it's a race to get to the first test
    # before the nodes get booted far enough to start being
    # seen by RackHD. Logically, it would be better IN runTests.
    # We do it between the vagrant and waitForAPI to use the
    # time to make the env instead of doing sleeps...
    setupVirtualEnv
    waitForAPI
    nodesOn &
    # Doesn't support ova smoke test now
    # generateSolLog
    # Run tests
    runTests
    # exit venv
    deactivate

    # Remedial work
    # Specific remedial work
    fetchOVALog

    # Clean Up below

    #shutdown vagrant box and delete all resource (like removing vm disk files in "~/VirtualBox VMs/")
    cleanupVMs
    nodesDelete
  elif [ "$TEST_TYPE" == "docker" ]; then
    # based on the assumption that in the same folder, the VMs has been exist normally. so don't destroy VM here.
    
    nodesCreate
    
    # Prepare RackHD
    # Forward local host port to ova
    portForwarding localhost

    # We setup the virtual-environment here, since once we
    # call "nodesOn", it's a race to get to the first test
    # before the nodes get booted far enough to start being
    # seen by RackHD. Logically, it would be better IN runTests.
    # We do it between the vagrant and waitForAPI to use the
    # time to make the env instead of doing sleeps...
    setupVirtualEnv
    waitForAPI
    nodesOn &
    # Doesn't support ova smoke test now
    # generateSolLog
    # Run tests
    runTests
    # exit venv
    deactivate

    # Clean Up below

    #shutdown vagrant box and delete all resource (like removing vm disk files in "~/VirtualBox VMs/")
    cleanupVMs
    nodesDelete
  else
    # rese the UCSPE emulators 
    ucsReset

    # register the signal handler to clean up( vagrantDestroy ), with process being killed
    trap cleanupVMs SIGINT SIGTERM SIGKILL
    cleanupVMs

    # based on the assumption that in the same folder, the VMs has been exist normally. so don't destroy VM here.
    
    nodesCreate
    # Power on vagrant box and nodes 
    vagrantUp
    # We setup the virtual-environment here, since once we
    # call "nodesOn", it's a race to get to the first test
    # before the nodes get booted far enough to start being
    # seen by RackHD. Logically, it would be better IN runTests.
    # We do it between the vagrant and waitForAPI to use the
    # time to make the env instead of doing sleeps...
    setupVirtualEnv
    waitForAPI
    nodesOn &
    generateSolLog
    # Run tests
    runTests
    generateSysLog

    # Clean Up below

    #shutdown vagrant box and delete all resource (like removing vm disk files in "~/VirtualBox VMs/")
    cleanupVMs
    nodesDelete
  fi

fi
