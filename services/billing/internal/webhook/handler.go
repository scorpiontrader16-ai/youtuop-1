package webhook

import (
	"context"
	"encoding/json"
	"fmt"
	"time"

	"github.com/stripe/stripe-go/v81"
	"go.uber.org/zap"

	"github.com/aminpola2001-ctrl/youtuop/services/billing/internal/postgres"
)

// Handler يعالج كل Stripe webhook events
// كل event بيتحفظ في billing_events أولاً (idempotency)
// ثم بيتعمل process
type Handler struct {
	db  *postgres.Client
	log *zap.Logger
}

func New(db *postgres.Client, log *zap.Logger) *Handler {
	return &Handler{db: db, log: log}
}

// Process يعالج Stripe event واحدة
func (h *Handler) Process(ctx context.Context, event stripe.Event, rawPayload []byte) error {
	// 1. تحقق إن الـ event مش اتعمل قبل كده
	processed, err := h.db.IsEventProcessed(ctx, event.ID)
	if err != nil {
		return fmt.Errorf("check event processed: %w", err)
	}
	if processed {
		h.log.Info("stripe event already processed — skipping",
			zap.String("event_id", event.ID),
			zap.String("event_type", string(event.Type)),
		)
		return nil
	}

	// 2. حفظ الـ event (idempotency record)
	if err := h.db.StoreBillingEvent(ctx, event.ID, string(event.Type), rawPayload); err != nil {
		h.log.Warn("store billing event failed", zap.Error(err))
	}

	// 3. عالج الـ event حسب نوعه
	var processErr error
	switch event.Type {

	case "customer.subscription.created",
		"customer.subscription.updated":
		processErr = h.handleSubscriptionUpdated(ctx, event)

	case "customer.subscription.deleted":
		processErr = h.handleSubscriptionDeleted(ctx, event)

	case "invoice.payment_succeeded":
		processErr = h.handleInvoicePaymentSucceeded(ctx, event)

	case "invoice.payment_failed":
		processErr = h.handleInvoicePaymentFailed(ctx, event)

	case "invoice.created",
		"invoice.finalized":
		processErr = h.handleInvoiceUpsert(ctx, event)

	default:
		h.log.Debug("unhandled stripe event type",
			zap.String("event_type", string(event.Type)),
		)
	}

	// 4. سجّل النتيجة
	if markErr := h.db.MarkEventProcessed(ctx, event.ID, processErr); markErr != nil {
		h.log.Warn("mark event processed failed", zap.Error(markErr))
	}

	if processErr != nil {
		h.log.Error("stripe event processing failed",
			zap.String("event_id", event.ID),
			zap.String("event_type", string(event.Type)),
			zap.Error(processErr),
		)
		return processErr
	}

	h.log.Info("stripe event processed",
		zap.String("event_id", event.ID),
		zap.String("event_type", string(event.Type)),
	)
	return nil
}

// ── Event Handlers ────────────────────────────────────────────────────────

func (h *Handler) handleSubscriptionUpdated(ctx context.Context, event stripe.Event) error {
	var sub stripe.Subscription
	if err := json.Unmarshal(event.Data.Raw, &sub); err != nil {
		return fmt.Errorf("unmarshal subscription: %w", err)
	}

	plan := sub.Metadata["plan"]
	if plan == "" {
		// جيب الـ plan من الـ price metadata لو مش موجود في الـ subscription
		if len(sub.Items.Data) > 0 && sub.Items.Data[0].Price != nil {
			plan = sub.Items.Data[0].Price.Metadata["plan"]
		}
	}
	if plan == "" {
		h.log.Warn("subscription has no plan metadata",
			zap.String("subscription_id", sub.ID),
		)
		plan = "basic" // safe fallback
	}

	var periodStart, periodEnd *time.Time
	if sub.CurrentPeriodStart != 0 {
		t := time.Unix(sub.CurrentPeriodStart, 0)
		periodStart = &t
	}
	if sub.CurrentPeriodEnd != 0 {
		t := time.Unix(sub.CurrentPeriodEnd, 0)
		periodEnd = &t
	}

	return h.db.UpdateSubscriptionFromStripe(ctx,
		sub.ID,
		string(sub.Status),
		plan,
		periodStart,
		periodEnd,
		sub.CancelAtPeriodEnd,
	)
}

func (h *Handler) handleSubscriptionDeleted(ctx context.Context, event stripe.Event) error {
	var sub stripe.Subscription
	if err := json.Unmarshal(event.Data.Raw, &sub); err != nil {
		return fmt.Errorf("unmarshal subscription: %w", err)
	}
	return h.db.UpdateSubscriptionFromStripe(ctx,
		sub.ID, "cancelled", "basic",
		nil, nil, false,
	)
}

func (h *Handler) handleInvoicePaymentSucceeded(ctx context.Context, event stripe.Event) error {
	var inv stripe.Invoice
	if err := json.Unmarshal(event.Data.Raw, &inv); err != nil {
		return fmt.Errorf("unmarshal invoice: %w", err)
	}

	tenantID := inv.Metadata["tenant_id"]
	if tenantID == "" && inv.Customer != nil {
		tenantID = inv.Customer.Metadata["tenant_id"]
	}

	now := time.Now()
	return h.db.UpsertInvoiceFromStripe(ctx,
		tenantID, inv.ID, "paid", string(inv.Currency),
		inv.AmountDue, inv.AmountPaid,
		nullStr(inv.InvoicePDF), nullStr(inv.HostedInvoiceURL),
		unixToTime(inv.PeriodStart), unixToTime(inv.PeriodEnd),
		unixToTime(inv.DueDate), &now,
	)
}

func (h *Handler) handleInvoicePaymentFailed(ctx context.Context, event stripe.Event) error {
	var inv stripe.Invoice
	if err := json.Unmarshal(event.Data.Raw, &inv); err != nil {
		return fmt.Errorf("unmarshal invoice: %w", err)
	}

	tenantID := inv.Metadata["tenant_id"]
	if tenantID == "" && inv.Customer != nil {
		tenantID = inv.Customer.Metadata["tenant_id"]
	}

	h.log.Warn("invoice payment failed",
		zap.String("invoice_id", inv.ID),
		zap.String("tenant_id", tenantID),
		zap.Int64("amount_due", inv.AmountDue),
	)

	return h.db.UpsertInvoiceFromStripe(ctx,
		tenantID, inv.ID, "open", string(inv.Currency),
		inv.AmountDue, inv.AmountPaid,
		nullStr(inv.InvoicePDF), nullStr(inv.HostedInvoiceURL),
		unixToTime(inv.PeriodStart), unixToTime(inv.PeriodEnd),
		unixToTime(inv.DueDate), nil,
	)
}

func (h *Handler) handleInvoiceUpsert(ctx context.Context, event stripe.Event) error {
	var inv stripe.Invoice
	if err := json.Unmarshal(event.Data.Raw, &inv); err != nil {
		return fmt.Errorf("unmarshal invoice: %w", err)
	}

	tenantID := inv.Metadata["tenant_id"]
	if tenantID == "" && inv.Customer != nil {
		tenantID = inv.Customer.Metadata["tenant_id"]
	}

	return h.db.UpsertInvoiceFromStripe(ctx,
		tenantID, inv.ID, string(inv.Status), string(inv.Currency),
		inv.AmountDue, inv.AmountPaid,
		nullStr(inv.InvoicePDF), nullStr(inv.HostedInvoiceURL),
		unixToTime(inv.PeriodStart), unixToTime(inv.PeriodEnd),
		unixToTime(inv.DueDate), nil,
	)
}

// ── Helpers ───────────────────────────────────────────────────────────────

func unixToTime(ts int64) *time.Time {
	if ts == 0 {
		return nil
	}
	t := time.Unix(ts, 0)
	return &t
}

func nullStr(s string) *string {
	if s == "" {
		return nil
	}
	return &s
}
