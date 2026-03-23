package elastic

import (
    "bytes"
    "context"
    "encoding/json"
    "fmt"
    "log/slog"
    "net/http"

    "github.com/elastic/go-elasticsearch/v8"
    "github.com/elastic/go-elasticsearch/v8/esapi"
)

type Client struct {
    es *elasticsearch.Client
}

type SearchRequest struct {
    Index   string                 `json:"-"`
    Query   map[string]interface{} `json:"query"`
    Size    int                    `json:"size"`
    From    int                    `json:"from"`
    Sort    []interface{}          `json:"sort,omitempty"`
    Aggs    map[string]interface{} `json:"aggs,omitempty"`
}

type SearchResult struct {
    Hits         []Hit                  `json:"hits"`
    Total        int64                  `json:"total"`
    Aggregations map[string]interface{} `json:"aggregations,omitempty"`
    Took         int64                  `json:"took"`
}

type Hit struct {
    ID     string          `json:"_id"`
    Index  string          `json:"_index"`
    Source json.RawMessage `json:"_source"`
}

func NewClient(cfg elasticsearch.Config) (*Client, error) {
    es, err := elasticsearch.NewClient(cfg)
    if err != nil {
        return nil, fmt.Errorf("failed to create elastic client: %w", err)
    }
    _, err = es.Info()
    if err != nil {
        return nil, fmt.Errorf("elasticsearch info failed: %w", err)
    }
    slog.Info("Elasticsearch connected")
    return &Client{es: es}, nil
}

func (c *Client) Search(ctx context.Context, req SearchRequest) (*SearchResult, error) {
    body, err := json.Marshal(req)
    if err != nil {
        return nil, fmt.Errorf("marshal request: %w", err)
    }

    res, err := c.es.Search(
        c.es.Search.WithContext(ctx),
        c.es.Search.WithIndex(req.Index),
        c.es.Search.WithBody(bytes.NewReader(body)),
        c.es.Search.WithTrackTotalHits(true),
    )
    if err != nil {
        return nil, fmt.Errorf("search error: %w", err)
    }
    defer res.Body.Close()

    if res.StatusCode != http.StatusOK {
        return nil, fmt.Errorf("elasticsearch returned %s", res.Status())
    }

    var result map[string]interface{}
    if err := json.NewDecoder(res.Body).Decode(&result); err != nil {
        return nil, fmt.Errorf("decode response: %w", err)
    }

    hits := result["hits"].(map[string]interface{})
    total := int64(hits["total"].(map[string]interface{})["value"].(float64))
    hitList := hits["hits"].([]interface{})

    out := &SearchResult{
        Total: total,
        Took:  int64(result["took"].(float64)),
    }

    for _, h := range hitList {
        hit := h.(map[string]interface{})
        src, _ := json.Marshal(hit["_source"])
        out.Hits = append(out.Hits, Hit{
            ID:     hit["_id"].(string),
            Index:  hit["_index"].(string),
            Source: src,
        })
    }

    if aggs, ok := result["aggregations"]; ok {
        out.Aggregations = aggs.(map[string]interface{})
    }

    return out, nil
}

// Info returns cluster info for health checks
func (c *Client) Info() (*esapi.Response, error) {
    return c.es.Info()
}
