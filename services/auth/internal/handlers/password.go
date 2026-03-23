package handlers

import (
    "errors"
    "github.com/trustelem/zxcvbn"
)

type PasswordPolicy struct {
    MinLength        int
    RequireUpper     bool
    RequireLower     bool
    RequireDigit     bool
    RequireSpecial   bool
    MinStrengthScore int // zxcvbn score 0-4
}

var DefaultPolicy = PasswordPolicy{
    MinLength:        8,
    RequireUpper:     true,
    RequireLower:     true,
    RequireDigit:     true,
    RequireSpecial:   true,
    MinStrengthScore: 3,
}

func ValidatePassword(password string, policy PasswordPolicy) error {
    if len(password) < policy.MinLength {
        return errors.New("password must be at least 8 characters")
    }
    hasUpper := false
    hasLower := false
    hasDigit := false
    hasSpecial := false
    for _, ch := range password {
        switch {
        case 'A' <= ch && ch <= 'Z':
            hasUpper = true
        case 'a' <= ch && ch <= 'z':
            hasLower = true
        case '0' <= ch && ch <= '9':
            hasDigit = true
        default:
            hasSpecial = true
        }
    }
    if policy.RequireUpper && !hasUpper {
        return errors.New("password must contain an uppercase letter")
    }
    if policy.RequireLower && !hasLower {
        return errors.New("password must contain a lowercase letter")
    }
    if policy.RequireDigit && !hasDigit {
        return errors.New("password must contain a digit")
    }
    if policy.RequireSpecial && !hasSpecial {
        return errors.New("password must contain a special character")
    }
    result := zxcvbn.PasswordStrength(password, nil)
    if result.Score < policy.MinStrengthScore {
        return errors.New("password is too weak")
    }
    return nil
}
