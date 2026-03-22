package resend

import (
	"bytes"
	"context"
	"fmt"
	htmltmpl "html/template"
	"strings"
	texttmpl "text/template"

	"github.com/resend/resend-go/v2"
)

type Client struct {
	rc       *resend.Client
	fromName string
	fromAddr string
}

func New(apiKey, fromName, fromAddr string) *Client {
	return &Client{
		rc:       resend.NewClient(apiKey),
		fromName: fromName,
		fromAddr: fromAddr,
	}
}

type SendResult struct {
	ID    string
	Error error
}

func (c *Client) Send(ctx context.Context, to, subject, htmlBody, textBody string) (*SendResult, error) {
	from := fmt.Sprintf("%s <%s>", c.fromName, c.fromAddr)
	params := &resend.SendEmailRequest{
		From:    from,
		To:      []string{to},
		Subject: subject,
		Html:    htmlBody,
		Text:    textBody,
	}
	resp, err := c.rc.Emails.Send(params)
	if err != nil {
		return &SendResult{Error: err}, fmt.Errorf("resend send: %w", err)
	}
	return &SendResult{ID: resp.Id}, nil
}

func RenderText(tmplStr string, data any) (string, error) {
	tmpl, err := texttmpl.New("").Parse(tmplStr)
	if err != nil {
		return "", fmt.Errorf("parse template: %w", err)
	}
	var buf strings.Builder
	if err := tmpl.Execute(&buf, data); err != nil {
		return "", fmt.Errorf("execute template: %w", err)
	}
	return buf.String(), nil
}

func RenderHTML(tmplStr string, data any) (string, error) {
	tmpl, err := htmltmpl.New("").Parse(tmplStr)
	if err != nil {
		return "", fmt.Errorf("parse html template: %w", err)
	}
	var buf bytes.Buffer
	if err := tmpl.Execute(&buf, data); err != nil {
		return "", fmt.Errorf("execute html template: %w", err)
	}
	return buf.String(), nil
}
