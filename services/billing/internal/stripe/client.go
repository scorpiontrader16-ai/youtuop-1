package stripe

import (
	"context"
	"fmt"

	"github.com/stripe/stripe-go/v81"
	"github.com/stripe/stripe-go/v81/client"
	"github.com/stripe/stripe-go/v81/webhook"
)

// PlanPriceIDs — Stripe Price IDs لكل plan
type PriceIDs struct {
	Basic      string
	Pro        string
	Business   string
	Enterprise string
}

// Client يتعامل مع Stripe API
type Client struct {
	sc       *client.API
	priceIDs PriceIDs
}

func New(secretKey string, priceIDs PriceIDs) *Client {
	sc := &client.API{}
	sc.Init(secretKey, nil)
	return &Client{sc: sc, priceIDs: priceIDs}
}

// PriceIDForPlan يرجع الـ Stripe Price ID للـ plan
func (c *Client) PriceIDForPlan(plan string) (string, error) {
	switch plan {
	case "basic":
		return c.priceIDs.Basic, nil
	case "pro":
		return c.priceIDs.Pro, nil
	case "business":
		return c.priceIDs.Business, nil
	case "enterprise":
		return c.priceIDs.Enterprise, nil
	}
	return "", fmt.Errorf("unknown plan: %s", plan)
}

// CreateCustomer ينشئ Stripe customer للـ tenant
func (c *Client) CreateCustomer(ctx context.Context, tenantID, tenantName, email string) (string, error) {
	params := &stripe.CustomerParams{
		Name:  stripe.String(tenantName),
		Email: stripe.String(email),
		Metadata: map[string]string{
			"tenant_id": tenantID,
			"platform":  "youtuop",
		},
	}
	cust, err := c.sc.Customers.New(params)
	if err != nil {
		return "", fmt.Errorf("create stripe customer: %w", err)
	}
	return cust.ID, nil
}

// CreateSubscription ينشئ Stripe subscription للـ customer
func (c *Client) CreateSubscription(ctx context.Context, customerID, plan string, trialDays int64) (*stripe.Subscription, error) {
	priceID, err := c.PriceIDForPlan(plan)
	if err != nil {
		return nil, err
	}

	params := &stripe.SubscriptionParams{
		Customer: stripe.String(customerID),
		Items: []*stripe.SubscriptionItemsParams{
			{Price: stripe.String(priceID)},
		},
		PaymentBehavior: stripe.String("default_incomplete"),
		Metadata: map[string]string{
			"platform": "youtuop",
			"plan":     plan,
		},
	}

	if trialDays > 0 {
		params.TrialPeriodDays = stripe.Int64(trialDays)
	}

	sub, err := c.sc.Subscriptions.New(params)
	if err != nil {
		return nil, fmt.Errorf("create stripe subscription: %w", err)
	}
	return sub, nil
}

// UpdateSubscriptionPlan يغيّر الـ plan على Stripe subscription موجودة
func (c *Client) UpdateSubscriptionPlan(ctx context.Context, stripeSubID, newPlan string) (*stripe.Subscription, error) {
	priceID, err := c.PriceIDForPlan(newPlan)
	if err != nil {
		return nil, err
	}

	sub, err := c.sc.Subscriptions.Get(stripeSubID, nil)
	if err != nil {
		return nil, fmt.Errorf("get stripe subscription: %w", err)
	}

	if len(sub.Items.Data) == 0 {
		return nil, fmt.Errorf("subscription has no items: %s", stripeSubID)
	}

	params := &stripe.SubscriptionParams{
		Items: []*stripe.SubscriptionItemsParams{
			{
				ID:    stripe.String(sub.Items.Data[0].ID),
				Price: stripe.String(priceID),
			},
		},
		Metadata: map[string]string{
			"plan": newPlan,
		},
		ProrationBehavior: stripe.String("create_prorations"),
	}

	updated, err := c.sc.Subscriptions.Update(stripeSubID, params)
	if err != nil {
		return nil, fmt.Errorf("update stripe subscription: %w", err)
	}
	return updated, nil
}

// CancelSubscription يلغي الـ subscription
func (c *Client) CancelSubscription(ctx context.Context, stripeSubID string, immediately bool) error {
	if immediately {
		_, err := c.sc.Subscriptions.Cancel(stripeSubID, nil)
		return err
	}
	params := &stripe.SubscriptionParams{
		CancelAtPeriodEnd: stripe.Bool(true),
	}
	_, err := c.sc.Subscriptions.Update(stripeSubID, params)
	return err
}

// CreatePortalSession ينشئ Stripe Customer Portal session
func (c *Client) CreatePortalSession(ctx context.Context, customerID, returnURL string) (string, error) {
	params := &stripe.BillingPortalSessionParams{
		Customer:  stripe.String(customerID),
		ReturnURL: stripe.String(returnURL),
	}
	session, err := c.sc.BillingPortalSessions.New(params)
	if err != nil {
		return "", fmt.Errorf("create portal session: %w", err)
	}
	return session.URL, nil
}

// ConstructWebhookEvent يتحقق من الـ webhook signature
// في stripe-go v72+ الـ function موجودة في webhook package
func ConstructWebhookEvent(payload []byte, sigHeader, webhookSecret string) (stripe.Event, error) {
	return webhook.ConstructEvent(payload, sigHeader, webhookSecret)
}
