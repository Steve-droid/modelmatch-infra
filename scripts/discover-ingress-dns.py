#!/usr/bin/env python3
"""Read-only Service -> AWS NLB discovery. Print a reviewed tfvars assignment, never apply."""
import argparse
import json
import subprocess


def read_json(command):
    return json.loads(subprocess.check_output(command, text=True))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--region", required=True)
    parser.add_argument("--account-id", required=True)
    parser.add_argument("--context", required=True, help="Explicit kubectl context to inspect")
    parser.add_argument("--namespace", default="nginx-ingress")
    parser.add_argument("--service", default="nginx-ingress-controller")
    args = parser.parse_args()
    identity = read_json(["aws", "sts", "get-caller-identity", "--output", "json"])
    if identity["Account"] != args.account_id:
        raise SystemExit("AWS account mismatch; no changes made")
    service = read_json(["kubectl", "--context", args.context, "-n", args.namespace,
                         "get", "service", args.service, "-o", "json"])
    hosts = {item.get("hostname", "").rstrip(".") for item in
             service.get("status", {}).get("loadBalancer", {}).get("ingress", [])}
    lbs = read_json(["aws", "elbv2", "describe-load-balancers", "--region", args.region,
                     "--output", "json"])["LoadBalancers"]
    matches = [lb for lb in lbs if lb["DNSName"].rstrip(".") in hosts
               and lb["Type"] == "network" and lb["Scheme"] == "internet-facing"]
    if len(matches) != 1:
        raise SystemExit("Expected exactly one public NLB matching the ingress Service; no changes made")
    lb = matches[0]
    print("# Verified Kubernetes Service -> public NLB. Review dns/dev.tfvars and terraform plan.")
    print(f'# Alias DNS: {lb["DNSName"]}; canonical zone: {lb["CanonicalHostedZoneId"]}')
    print("ingress_nlb_arn = " + json.dumps(lb["LoadBalancerArn"]))


if __name__ == "__main__":
    main()
