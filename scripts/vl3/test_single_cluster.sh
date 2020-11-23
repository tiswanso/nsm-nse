#!/bin/bash

usage() {
  echo "usage: $0 [OPTIONS]"
  echo ""
  echo "  MANDATORY OPTIONS:"
  echo ""
  echo "  --kconf=<kubeconfig>           set the kubeconfig for the first cluster"
  echo ""
  echo "  Optional OPTIONS:"
  echo ""
  echo "  --namespace=<namespace>    set the namespace to watch for NSM clients"
  echo "  --mysql                    add mysql replication deployment to demo"
  echo "  --svcreg                   install NSM-dns service registry"
  echo "  --delete                   delete the installation"
  echo "  --nowait                   don't wait for user input prior to moving to next step"
  echo ""
}

NSMISTIODIR=${GOPATH}/src/github.com/nsm-istio
sdir=$(dirname ${0})
HELMDIR=${sdir}/../../deployments/helm
MFSTDIR=${MFSTDIR:-${sdir}/../k8s}
WCMNSR=foo.com

for i in "$@"; do
    case $i in
        -h|--help)
            usage
            exit
            ;;
        --kconf=?*)
            KCONF_CLUS1=${i#*=}
            echo "setting cluster 1=${KCONF_CLUS1}" 
            ;;
        --namespace=?*)
            NAMESPACE=${i#*=}
            ;;
        --delete)
            DELETE=true
            ;;
        --mysql)
            MYSQL=true
            ;;
        --svcreg)
            SVCREG=true
            ;;
        --nowait)
            NOWAIT=true
            ;;
        --hello)
            HELLO=true
            ;;
        *)
            usage
            exit 1
            ;;
    esac
done

if [[ -z ${KCONF_CLUS1} ]]; then
    echo "ERROR: One or more of kubeconfigs not set."
    usage
    exit 1
fi


########################
# include the magic
########################
DEMOMAGIC=${DEMOMAGIC:-${sdir}/demo-magic.sh}
. ${DEMOMAGIC} -d ${NOWAIT:+-n}

# hide the evidence
clear

function pc {
    pe "$@"
    #pe "clear"
    echo "----DONE---- $@"
    if [[ -z ${NOWAIT} ]]; then
        wait
    fi
    clear
}

echo
p "# --------------------- NSM Installation + Inter-domain Setup ------------------------"

pe "# **** Install NSM in cluster 1"
pc "${DELETE:+INSTALL_OP=delete} KCONF=${KCONF_CLUS1} scripts/vl3/nsm_install_interdomain.sh"
echo

if [[ -z ${DELETE} ]]; then
    p "# **** Wait for NSM pods to be ready in cluster 1"
    kubectl wait --kubeconfig ${KCONF_CLUS1} --timeout=150s --for condition=Ready -l app=nsm-admission-webhook -n nsm-system pod
    kubectl wait --kubeconfig ${KCONF_CLUS1} --timeout=150s --for condition=Ready -l app=nsmgr-daemonset -n nsm-system pod
    kubectl wait --kubeconfig ${KCONF_CLUS1} --timeout=150s --for condition=Ready -l app=proxy-nsmgr-daemonset -n nsm-system pod
    kubectl wait --kubeconfig ${KCONF_CLUS1} --timeout=150s --for condition=Ready -l app=nsm-vpp-plane -n nsm-system pod

    echo
    p "# **** Show NSM pods in cluster 1"
    pc "kubectl get pods --kubeconfig ${KCONF_CLUS1} -n nsm-system -o wide"
    echo

fi

p "# --------------------- Virtual L3 Setup ------------------------"

pe "# **** Install vL3 in cluster 1"
pc "${DELETE:+INSTALL_OP=delete} REMOTE_IP=${clus2_IP} KCONF=${KCONF_CLUS1} PULLPOLICY=Always NSEREPLICAS=${NSEREPLICAS:-1} scripts/vl3/vl3_interdomain.sh --ipamOctet=22 ${WCM_NSRADDR:+--wcmNsrAddr=${WCM_NSRADDR}} ${WCM_NSRPORT:+--wcmNsrPort=${WCM_NSRPORT}}"
pc "kubectl get pods --kubeconfig ${KCONF_CLUS1} -o wide"
echo

p "# **** Virtual L3 service definition (CRD) ***"
pe "helm template deployments/helm/vl3_hello --set replicaCount=1"
echo
p "# **** Cluster 1 vL3 NSEs"
pe "kubectl get pods --kubeconfig ${KCONF_CLUS1} -l networkservicemesh.io/app=vl3-nse-ucnf -o wide"
echo

if [[ -n ${HELLO} ]]; then
    INSTALL_OP=apply
    if [ "${DELETE}" == "true" ]; then
        INSTALL_OP=delete
    fi

    p "# **** Install helloworld in cluster 1 ****"
    pe "helm template deployments/helm/vl3_hello --set replicaCount=1 | kubectl ${INSTALL_OP} --kubeconfig ${KCONF_CLUS1} -f -"

    if [[ "$INSTALL_OP" != "delete" ]]; then
        sleep 10
        kubectl wait --kubeconfig ${KCONF_CLUS1} --timeout=150s --for condition=Ready -l app=helloworld pod
    fi

fi
