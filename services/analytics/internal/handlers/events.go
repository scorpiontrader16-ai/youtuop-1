package handlers

import (
    "net/http"
    "time"

    "github.com/gofiber/fiber/v2"
    "github.com/jackc/pgx/v5"
)

type Event struct {
    UserID     string                 `json:"user_id"`
    SessionID  string                 `json:"session_id,omitempty"`
    EventType  string                 `json:"event_type"`
    EventName  string                 `json:"event_name"`
    Properties map[string]interface{} `json:"properties,omitempty"`
    Timestamp  time.Time              `json:"timestamp,omitempty"`
}

type EventHandler struct {
    db *pgx.Conn
}

func NewEventHandler(db *pgx.Conn) *EventHandler {
    return &EventHandler{db: db}
}

func (h *EventHandler) Track(c *fiber.Ctx) error {
    tenantID := c.Get("X-Tenant-ID")
    if tenantID == "" {
        return c.Status(http.StatusBadRequest).JSON(fiber.Map{"error": "missing tenant id"})
    }

    var ev Event
    if err := c.BodyParser(&ev); err != nil {
        return c.Status(http.StatusBadRequest).JSON(fiber.Map{"error": "invalid request"})
    }
    if ev.Timestamp.IsZero() {
        ev.Timestamp = time.Now().UTC()
    }

    ip := c.IP()
    ua := c.Get("User-Agent")

    _, err := h.db.Exec(c.Context(),
        `INSERT INTO analytics_events (tenant_id, user_id, session_id, event_type, event_name, properties, timestamp, ip_address, user_agent)
         VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9)`,
        tenantID, ev.UserID, ev.SessionID, ev.EventType, ev.EventName, ev.Properties, ev.Timestamp, ip, ua,
    )
    if err != nil {
        return c.Status(http.StatusInternalServerError).JSON(fiber.Map{"error": "failed to record event"})
    }

    return c.Status(http.StatusAccepted).JSON(fiber.Map{"status": "tracked"})
}
