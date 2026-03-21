package jwt

import (
	"crypto/rsa"
	"crypto/x509"
	"encoding/base64"
	"encoding/json"
	"encoding/pem"
	"errors"
	"fmt"
	"math/big"
	"time"

	gojwt "github.com/golang-jwt/jwt/v5"
	"github.com/google/uuid"
)

const (
	AccessTokenTTL  = 15 * time.Minute
	RefreshTokenTTL = 30 * 24 * time.Hour
)

// Claims هي الـ payload في كل access token.
// UserID محفوظ في RegisteredClaims.Subject (json:"sub") — مفيش تكرار.
// باقي الـ fields هي custom claims.
type Claims struct {
	// M8: بيانات الـ session
	Email     string `json:"email"`
	SessionID string `json:"sid"`

	// M9: الـ tenant
	TenantID   string `json:"tid"`
	TenantSlug string `json:"tslug"`
	Plan       string `json:"plan"`

	// M10: الـ permissions
	Role        string   `json:"role"`
	Permissions []string `json:"perms"`

	// RegisteredClaims.Subject = UserID (json:"sub")
	gojwt.RegisteredClaims
}

// UserID يرجع الـ user ID من الـ Subject claim
func (c *Claims) UserID() string { return c.Subject }

// IssueInput — input لإصدار token جديد
type IssueInput struct {
	UserID     string
	Email      string
	SessionID  string
	TenantID   string
	TenantSlug string
	Plan       string
	Role       string
	Permissions []string
}

// ── Service ───────────────────────────────────────────────────────────────

type Service struct {
	privateKey *rsa.PrivateKey
	publicKey  *rsa.PublicKey
	issuer     string
	keyID      string
}

func NewService(privateKeyPEM []byte, issuer string) (*Service, error) {
	block, _ := pem.Decode(privateKeyPEM)
	if block == nil {
		return nil, errors.New("failed to decode PEM block")
	}

	// Try PKCS8 first, then PKCS1
	var rsaKey *rsa.PrivateKey
	if key, err := x509.ParsePKCS8PrivateKey(block.Bytes); err == nil {
		var ok bool
		rsaKey, ok = key.(*rsa.PrivateKey)
		if !ok {
			return nil, errors.New("key is not RSA")
		}
	} else if key, err := x509.ParsePKCS1PrivateKey(block.Bytes); err == nil {
		rsaKey = key
	} else {
		return nil, fmt.Errorf("parse RSA private key: %w", err)
	}

	return &Service{
		privateKey: rsaKey,
		publicKey:  &rsaKey.PublicKey,
		issuer:     issuer,
		keyID:      "v1",
	}, nil
}

// IssueAccessToken يصدر JWT موقّع بـ RS256
func (s *Service) IssueAccessToken(in IssueInput) (string, error) {
	now := time.Now()
	c := Claims{
		Email:       in.Email,
		SessionID:   in.SessionID,
		TenantID:    in.TenantID,
		TenantSlug:  in.TenantSlug,
		Plan:        in.Plan,
		Role:        in.Role,
		Permissions: in.Permissions,
		RegisteredClaims: gojwt.RegisteredClaims{
			Issuer:    s.issuer,
			Subject:   in.UserID, // UserID يتحفظ هنا كـ "sub"
			IssuedAt:  gojwt.NewNumericDate(now),
			ExpiresAt: gojwt.NewNumericDate(now.Add(AccessTokenTTL)),
			ID:        uuid.NewString(),
		},
	}
	t := gojwt.NewWithClaims(gojwt.SigningMethodRS256, c)
	t.Header["kid"] = s.keyID
	return t.SignedString(s.privateKey)
}

// Validate يتحقق من الـ JWT ويرجع الـ Claims
func (s *Service) Validate(tokenStr string) (*Claims, error) {
	t, err := gojwt.ParseWithClaims(tokenStr, &Claims{}, func(t *gojwt.Token) (any, error) {
		if _, ok := t.Method.(*gojwt.SigningMethodRSA); !ok {
			return nil, fmt.Errorf("unexpected signing method: %v", t.Header["alg"])
		}
		return s.publicKey, nil
	})
	if err != nil {
		return nil, fmt.Errorf("invalid token: %w", err)
	}
	c, ok := t.Claims.(*Claims)
	if !ok || !t.Valid {
		return nil, errors.New("malformed claims")
	}
	return c, nil
}

// JWKS يرجع الـ public key بصيغة JWK Set لـ /.well-known/jwks.json
func (s *Service) JWKS() ([]byte, error) {
	n := base64.RawURLEncoding.EncodeToString(s.publicKey.N.Bytes())
	e := base64.RawURLEncoding.EncodeToString(big.NewInt(int64(s.publicKey.E)).Bytes())
	return json.Marshal(map[string]any{
		"keys": []map[string]any{{
			"kty": "RSA",
			"use": "sig",
			"alg": "RS256",
			"kid": s.keyID,
			"n":   n,
			"e":   e,
		}},
	})
}
