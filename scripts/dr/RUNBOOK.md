# Disaster Recovery Runbook — youtuop Platform

## RTO / RPO Targets

| Metric | Target | Notes |
|--------|--------|-------|
| RTO (Recovery Time Objective) | 4 hours | الوقت من اكتشاف المشكلة لحد استعادة الخدمة |
| RPO (Recovery Point Objective) | 15 minutes | أقصى فقدان للبيانات |
| Backup Frequency | Hourly (incremental) + Daily (full) | Velero |
| Postgres Lag | < 15 minutes | Read replica في eu-west-1 |

---

## Architecture Overview

```
Primary (us-east-1)               DR (eu-west-1)
├── EKS: platform-prod            ├── EKS: platform-prod-dr
├── Postgres (multi-AZ)    ──────>├── Postgres Read Replica
├── Redpanda (3 brokers)          ├── Redpanda (3 brokers)
├── S3: results-sync-us   ──────>├── S3: dr-data-eu-west-1
└── Velero → S3 backups   ──────>└── S3: velero-backups-eu-west-1
```

---

## Trigger Conditions

**Automatic Alert:**
- Route53 health check fails 3 times in a row
- CloudWatch alarm: `platform-primary-region-health`
- SNS topic: `platform-dr-alerts`

**Manual Trigger:**
- Primary region outage > 30 minutes
- Data corruption detected
- Security incident requiring isolation

---

## قبل تشغيل الـ Runbook — استخرج المتغيرات

```bash
cd infra/terraform/environments/production

export HEALTH_CHECK_ID=$(terraform output -raw health_check_id)
export HOSTED_ZONE_ID=$(terraform output -raw hosted_zone_id)
export DR_KUBECONFIG="$HOME/.kube/platform-eu"
export DR_LB_DNS=$(grep dr_lb_dns terraform.tfvars | awk -F'"' '{print $2}')
export DR_LB_ZONE_ID=$(grep dr_lb_zone_id terraform.tfvars | awk -F'"' '{print $2}')

echo "HEALTH_CHECK_ID=$HEALTH_CHECK_ID"
echo "HOSTED_ZONE_ID=$HOSTED_ZONE_ID"
echo "DR_LB_DNS=$DR_LB_DNS"
echo "DR_LB_ZONE_ID=$DR_LB_ZONE_ID"
```

---

## Failover Procedure

### Phase 1 — Assessment (0–30 min)

```bash
# 1. تحقق من حالة الـ primary region
aws route53 get-health-check-status \
  --health-check-id $HEALTH_CHECK_ID \
  --region us-east-1

# 2. تحقق من الـ Postgres replica lag
aws rds describe-db-instances \
  --db-instance-identifier platform-prod-dr-postgres \
  --region eu-west-1 \
  --query 'DBInstances[0].StatusInfos'

# 3. تحقق من آخر Velero backup
velero backup get --kubeconfig $DR_KUBECONFIG
```

### Phase 2 — Postgres Failover (30–60 min)

```bash
# 1. Promote الـ read replica لـ standalone
aws rds promote-read-replica \
  --db-instance-identifier platform-prod-dr-postgres \
  --region eu-west-1

# 2. انتظر الـ promotion
aws rds wait db-instance-available \
  --db-instance-identifier platform-prod-dr-postgres \
  --region eu-west-1

# 3. جيب الـ endpoint الجديد
aws rds describe-db-instances \
  --db-instance-identifier platform-prod-dr-postgres \
  --region eu-west-1 \
  --query 'DBInstances[0].Endpoint.Address'
```

### Phase 3 — Update K8s Secrets (60–90 min)

```bash
# 1. اتصل بالـ DR cluster
aws eks update-kubeconfig \
  --name platform-prod-dr \
  --region eu-west-1

# 2. حدّث الـ Postgres endpoint في AWS Secrets Manager
aws secretsmanager update-secret \
  --secret-id platform/ingestion \
  --secret-string '{"POSTGRES_HOST":"<new-dr-endpoint>","POSTGRES_PORT":"5432"}' \
  --region eu-west-1

# كرر لكل service: auth, billing, notifications, control-plane, feature-flags

# 3. أعد تشغيل الـ pods عشان يأخدوا الـ secret الجديد
for service in ingestion auth billing notifications control-plane feature-flags; do
  kubectl rollout restart rollout/$service -n platform
done

# 4. تأكد إن كل الـ pods شغالة
kubectl get pods -n platform -w
```

### Phase 4 — DNS Failover (90–120 min)

```bash
# 1. حدّث الـ Route53 DNS للـ DR
aws route53 change-resource-record-sets \
  --hosted-zone-id $HOSTED_ZONE_ID \
  --change-batch '{
    "Changes": [{
      "Action": "UPSERT",
      "ResourceRecordSet": {
        "Name": "api.amnixfinance.com",
        "Type": "A",
        "AliasTarget": {
          "HostedZoneId": "'$DR_LB_ZONE_ID'",
          "DNSName": "'$DR_LB_DNS'",
          "EvaluateTargetHealth": true
        }
      }
    }]
  }'

# 2. تحقق من الـ DNS propagation
dig api.amnixfinance.com

# 3. اختبر الـ health endpoints
curl -f https://api.amnixfinance.com/healthz
curl -f https://api.amnixfinance.com/healthz/auth
curl -f https://api.amnixfinance.com/healthz/ingestion
```

### Phase 5 — Validation (120–240 min)

```bash
# 1. تحقق من كل الـ services
kubectl get rollouts -n platform
kubectl get pods -n platform

# 2. تحقق من الـ metrics
# Victoria Metrics dashboard: http://grafana.monitoring.svc.cluster.local

# 3. اختبر الـ auth flow
curl -X POST https://api.amnixfinance.com/v1/auth/login \
  -H "Content-Type: application/json" \
  -d '{"code":"test","redirect_uri":"test","tenant_slug":"test"}'

# 4. أبلّغ فريق الـ operations والـ customers
```

---

## Restore from Velero Backup

```bash
# 1. قائمة بكل الـ backups المتاحة
velero backup get --kubeconfig $DR_KUBECONFIG

# 2. Restore آخر backup
velero restore create \
  --from-backup platform-daily-full-<TIMESTAMP> \
  --namespace-mappings platform:platform \
  --kubeconfig $DR_KUBECONFIG

# 3. تابع الـ restore
velero restore describe platform-daily-full-<TIMESTAMP>-<RESTORE_SUFFIX>
```

---

## Failback Procedure (العودة للـ Primary)

بعد ما الـ primary يرجع:

```bash
# 1. تأكد إن الـ primary healthy
aws route53 get-health-check-status --health-check-id $HEALTH_CHECK_ID

# 2. Sync البيانات من DR للـ primary
# الـ Postgres replication بتبدأ تلقائياً لما الـ primary يرجع

# 3. أعد الـ DNS للـ primary
aws route53 change-resource-record-sets \
  --hosted-zone-id $HOSTED_ZONE_ID \
  --change-batch '{ ... primary LB ... }'

# 4. اعمل Postgres replica جديدة من الـ DR
aws rds create-db-instance-read-replica \
  --db-instance-identifier platform-prod-dr-postgres-new \
  --source-db-instance-identifier platform-prod-postgres \
  --region eu-west-1
```

---

## Contact List

| Role | Action |
|------|--------|
| On-call Engineer | يبدأ الـ runbook فوراً |
| CTO | يوافق على الـ DNS failover |
| Customer Success | يبلّغ الـ enterprise customers |
| Legal | لو في data breach — GDPR notification خلال 72 ساعة |

---

## Post-Mortem Checklist

- [ ] Timeline موثق بالكامل
- [ ] Root cause محدد
- [ ] Blameless post-mortem scheduled خلال 48 ساعة
- [ ] Action items في GitHub Issues
- [ ] Runbook محدث لو في gaps
- [ ] Customers أبلّغوا بالـ incident summary
