// Package onboarding provisions Kubernetes resources for a new tenant.
// Every function is idempotent — safe to call on every reconcile loop.
package onboarding

// ╔══════════════════════════════════════════════════════════════════╗
// ║  services/tenant-operator/internal/onboarding/onboarding.go     ║
// ║  M9 — Tenant onboarding: namespace + ResourceQuota + labels      ║
// ╚══════════════════════════════════════════════════════════════════╝

import (
	"context"
	"fmt"

	"go.uber.org/zap"
	corev1 "k8s.io/api/core/v1"
	"k8s.io/apimachinery/pkg/api/errors"
	"k8s.io/apimachinery/pkg/api/resource"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/client-go/kubernetes"
)

// tierQuota defines the ResourceQuota limits per tier.
// Sized conservatively — can be adjusted without code change via a ConfigMap in future.
var tierQuota = map[string]corev1.ResourceList{
	"basic": {
		corev1.ResourceRequestsCPU:    resource.MustParse("500m"),
		corev1.ResourceLimitsCPU:      resource.MustParse("2"),
		corev1.ResourceRequestsMemory: resource.MustParse("512Mi"),
		corev1.ResourceLimitsMemory:   resource.MustParse("2Gi"),
	},
	"pro": {
		corev1.ResourceRequestsCPU:    resource.MustParse("1"),
		corev1.ResourceLimitsCPU:      resource.MustParse("4"),
		corev1.ResourceRequestsMemory: resource.MustParse("1Gi"),
		corev1.ResourceLimitsMemory:   resource.MustParse("8Gi"),
	},
	"enterprise": {
		corev1.ResourceRequestsCPU:    resource.MustParse("2"),
		corev1.ResourceLimitsCPU:      resource.MustParse("8"),
		corev1.ResourceRequestsMemory: resource.MustParse("2Gi"),
		corev1.ResourceLimitsMemory:   resource.MustParse("16Gi"),
	},
}

// Provisioner handles all K8s resource creation for a single tenant.
type Provisioner struct {
	k8s    kubernetes.Interface
	logger *zap.Logger
}

// NewProvisioner creates a Provisioner backed by the given Kubernetes client.
func NewProvisioner(k8s kubernetes.Interface, logger *zap.Logger) *Provisioner {
	return &Provisioner{k8s: k8s, logger: logger}
}

// Provision ensures the full K8s footprint exists for the tenant.
// Returns nil if everything is already in place (idempotent).
func (p *Provisioner) Provision(ctx context.Context, tenantID, slug, tier string) error {
	nsName := fmt.Sprintf("tenant-%s", slug)

	if err := p.ensureNamespace(ctx, nsName, tenantID, tier); err != nil {
		return fmt.Errorf("namespace: %w", err)
	}

	if err := p.ensureResourceQuota(ctx, nsName, tier); err != nil {
		return fmt.Errorf("resource quota: %w", err)
	}

	p.logger.Info("tenant provisioned",
		zap.String("tenant_id", tenantID),
		zap.String("slug", slug),
		zap.String("tier", tier),
		zap.String("namespace", nsName),
	)
	return nil
}

// ensureNamespace creates the tenant namespace if it does not exist.
// Labels carry tier so HPA / policies can target by tier.
func (p *Provisioner) ensureNamespace(ctx context.Context, name, tenantID, tier string) error {
	_, err := p.k8s.CoreV1().Namespaces().Get(ctx, name, metav1.GetOptions{})
	if err == nil {
		return nil // already exists — nothing to do
	}
	if !errors.IsNotFound(err) {
		return fmt.Errorf("get namespace %s: %w", name, err)
	}

	ns := &corev1.Namespace{
		ObjectMeta: metav1.ObjectMeta{
			Name: name,
			Labels: map[string]string{
				"app.kubernetes.io/managed-by": "tenant-operator",
				"youtuop.io/tenant-id":         tenantID,
				"youtuop.io/tier":              tier,
			},
		},
	}
	if _, createErr := p.k8s.CoreV1().Namespaces().Create(ctx, ns, metav1.CreateOptions{}); createErr != nil {
		return fmt.Errorf("create namespace %s: %w", name, createErr)
	}
	p.logger.Info("namespace created", zap.String("namespace", name), zap.String("tier", tier))
	return nil
}

// ensureResourceQuota creates or updates the ResourceQuota for the tenant's tier.
// If the tier is unknown, basic limits are applied as a safe fallback.
func (p *Provisioner) ensureResourceQuota(ctx context.Context, namespace, tier string) error {
	limits, ok := tierQuota[tier]
	if !ok {
		p.logger.Warn("unknown tier — applying basic quota", zap.String("tier", tier))
		limits = tierQuota["basic"]
	}

	quotaName := "tenant-quota"
	desired := &corev1.ResourceQuota{
		ObjectMeta: metav1.ObjectMeta{
			Name:      quotaName,
			Namespace: namespace,
			Labels: map[string]string{
				"app.kubernetes.io/managed-by": "tenant-operator",
				"youtuop.io/tier":              tier,
			},
		},
		Spec: corev1.ResourceQuotaSpec{
			Hard: limits,
		},
	}

	existing, err := p.k8s.CoreV1().ResourceQuotas(namespace).Get(ctx, quotaName, metav1.GetOptions{})
	if errors.IsNotFound(err) {
		if _, createErr := p.k8s.CoreV1().ResourceQuotas(namespace).Create(ctx, desired, metav1.CreateOptions{}); createErr != nil {
			return fmt.Errorf("create resource quota: %w", createErr)
		}
		p.logger.Info("resource quota created", zap.String("namespace", namespace), zap.String("tier", tier))
		return nil
	}
	if err != nil {
		return fmt.Errorf("get resource quota: %w", err)
	}

	// Update if tier label changed (tenant upgraded / downgraded)
	existing.Spec.Hard = limits
	existing.Labels["youtuop.io/tier"] = tier
	if _, updateErr := p.k8s.CoreV1().ResourceQuotas(namespace).Update(ctx, existing, metav1.UpdateOptions{}); updateErr != nil {
		return fmt.Errorf("update resource quota: %w", updateErr)
	}
	p.logger.Info("resource quota updated", zap.String("namespace", namespace), zap.String("tier", tier))
	return nil
}
