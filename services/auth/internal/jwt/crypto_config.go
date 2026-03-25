package jwt

// ╔══════════════════════════════════════════════════════════════════╗
// ║  services/auth/internal/jwt/crypto_config.go                    ║
// ║  M5 – Crypto Agility: RS256 / ES256 hot-swap via env            ║
// ╚══════════════════════════════════════════════════════════════════╝

import (
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/rsa"
	"crypto/x509"
	"encoding/pem"
	"errors"
	"fmt"
	"os"
)

// Algorithm هي الـ signing algorithms المدعومة
type Algorithm string

const (
	AlgorithmRS256 Algorithm = "RS256"
	AlgorithmES256 Algorithm = "ES256"
)

// CryptoConfig تحمل الـ algorithm والـ keys
type CryptoConfig struct {
	Algorithm  Algorithm
	PrivateKey any // *rsa.PrivateKey | *ecdsa.PrivateKey
	PublicKey  any // *rsa.PublicKey  | *ecdsa.PublicKey
	KeyID      string
}

// LoadCryptoConfig يقرأ الـ config من الـ environment
//
// Environment variables:
//
//	JWT_ALGORITHM         = RS256 (default) | ES256
//	JWT_PRIVATE_KEY_PATH  = path to PEM file
//	JWT_KEY_ID            = key identifier for JWKS (default: "v1")
func LoadCryptoConfig() (*CryptoConfig, error) {
	alg := Algorithm(os.Getenv("JWT_ALGORITHM"))
	if alg == "" {
		alg = AlgorithmRS256
	}

	keyPath := os.Getenv("JWT_PRIVATE_KEY_PATH")
	if keyPath == "" {
		return nil, errors.New("JWT_PRIVATE_KEY_PATH is required")
	}

	keyID := os.Getenv("JWT_KEY_ID")
	if keyID == "" {
		keyID = "v1"
	}

	data, err := os.ReadFile(keyPath)
	if err != nil {
		return nil, fmt.Errorf("read private key file %q: %w", keyPath, err)
	}

	cfg := &CryptoConfig{Algorithm: alg, KeyID: keyID}

	switch alg {
	case AlgorithmRS256:
		key, err := parseRSAPrivateKey(data)
		if err != nil {
			return nil, fmt.Errorf("load RSA key: %w", err)
		}
		cfg.PrivateKey = key
		cfg.PublicKey = &key.PublicKey

	case AlgorithmES256:
		key, err := parseECDSAPrivateKey(data)
		if err != nil {
			return nil, fmt.Errorf("load ECDSA key: %w", err)
		}
		if key.Curve != elliptic.P256() {
			return nil, errors.New("ES256 requires a P-256 key")
		}
		cfg.PrivateKey = key
		cfg.PublicKey = &key.PublicKey

	default:
		return nil, fmt.Errorf("unsupported JWT algorithm %q — supported: RS256, ES256", alg)
	}

	return cfg, nil
}

// LoadCryptoConfigFromPEM مباشرة من bytes — للاختبار أو لما الـ key جاي من Vault/Secret
func LoadCryptoConfigFromPEM(alg Algorithm, privateKeyPEM []byte, keyID string) (*CryptoConfig, error) {
	if keyID == "" {
		keyID = "v1"
	}

	cfg := &CryptoConfig{Algorithm: alg, KeyID: keyID}

	switch alg {
	case AlgorithmRS256:
		key, err := parseRSAPrivateKey(privateKeyPEM)
		if err != nil {
			return nil, fmt.Errorf("parse RSA key: %w", err)
		}
		cfg.PrivateKey = key
		cfg.PublicKey = &key.PublicKey

	case AlgorithmES256:
		key, err := parseECDSAPrivateKey(privateKeyPEM)
		if err != nil {
			return nil, fmt.Errorf("parse ECDSA key: %w", err)
		}
		if key.Curve != elliptic.P256() {
			return nil, errors.New("ES256 requires a P-256 key")
		}
		cfg.PrivateKey = key
		cfg.PublicKey = &key.PublicKey

	default:
		return nil, fmt.Errorf("unsupported algorithm: %s", alg)
	}

	return cfg, nil
}

// GenerateRSAKeyPEM ينشئ RSA key جديد ويرجعه كـ PEM — للاختبار فقط
func GenerateRSAKeyPEM(bits int) ([]byte, error) {
	key, err := rsa.GenerateKey(rand.Reader, bits)
	if err != nil {
		return nil, err
	}
	der, err := x509.MarshalPKCS8PrivateKey(key)
	if err != nil {
		return nil, err
	}
	return pem.EncodeToMemory(&pem.Block{Type: "PRIVATE KEY", Bytes: der}), nil
}

// GenerateECDSAKeyPEM ينشئ ECDSA P-256 key جديد ويرجعه كـ PEM — للاختبار فقط
func GenerateECDSAKeyPEM() ([]byte, error) {
	key, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		return nil, err
	}
	der, err := x509.MarshalPKCS8PrivateKey(key)
	if err != nil {
		return nil, err
	}
	return pem.EncodeToMemory(&pem.Block{Type: "PRIVATE KEY", Bytes: der}), nil
}

// ── Internal parsers ─────────────────────────────────────────────────

func parseRSAPrivateKey(data []byte) (*rsa.PrivateKey, error) {
	block, _ := pem.Decode(data)
	if block == nil {
		return nil, errors.New("no PEM block found in key data")
	}

	// PKCS8 أولاً، ثم PKCS1
	if key, err := x509.ParsePKCS8PrivateKey(block.Bytes); err == nil {
		rsaKey, ok := key.(*rsa.PrivateKey)
		if !ok {
			return nil, errors.New("PKCS8 key is not RSA")
		}
		return rsaKey, nil
	}

	if key, err := x509.ParsePKCS1PrivateKey(block.Bytes); err == nil {
		return key, nil
	}

	return nil, errors.New("cannot parse RSA private key — must be PKCS8 or PKCS1 PEM")
}

func parseECDSAPrivateKey(data []byte) (*ecdsa.PrivateKey, error) {
	block, _ := pem.Decode(data)
	if block == nil {
		return nil, errors.New("no PEM block found in key data")
	}

	// PKCS8 أولاً، ثم SEC1
	if key, err := x509.ParsePKCS8PrivateKey(block.Bytes); err == nil {
		ecKey, ok := key.(*ecdsa.PrivateKey)
		if !ok {
			return nil, errors.New("PKCS8 key is not ECDSA")
		}
		return ecKey, nil
	}

	if key, err := x509.ParseECPrivateKey(block.Bytes); err == nil {
		return key, nil
	}

	return nil, errors.New("cannot parse ECDSA private key — must be PKCS8 or SEC1 PEM")
}
