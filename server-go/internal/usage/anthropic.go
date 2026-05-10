package usage

import (
	"context"
	"encoding/json"
	"net/http"

	"github.com/codemoo/token-terrier/server-go/internal/auth"
)

// claudeUsageResponse mirrors ClaudeUsageResponse — what Anthropic's
// `/api/oauth/usage` endpoint returns when the OAuth token is valid.
type claudeUsageResponse struct {
	FiveHour         *claudeWindow     `json:"five_hour"`
	SevenDay         *claudeWindow     `json:"seven_day"`
	SevenDaySonnet   *claudeWindow     `json:"seven_day_sonnet"`
	SevenDayOpus     *claudeWindow     `json:"seven_day_opus"`
	ExtraRateWindows []json.RawMessage `json:"extra_rate_windows"`
}

type claudeWindow struct {
	Utilization float64 `json:"utilization"`
	ResetsAt    string  `json:"resets_at"`
}

func (c *Client) fetchClaude(ctx context.Context, credential auth.OAuthCredential) (*claudeUsageResponse, error) {
	req, err := http.NewRequestWithContext(ctx, "GET", "https://api.anthropic.com/api/oauth/usage", nil)
	if err != nil {
		return nil, &APIError{Kind: KindInvalidResponse, Message: err.Error()}
	}
	req.Header.Set("Authorization", "Bearer "+credential.AccessToken)
	req.Header.Set("anthropic-beta", "oauth-2025-04-20")
	req.Header.Set("Accept", "application/json")
	body, err := c.execute(req)
	if err != nil {
		return nil, err
	}
	var resp claudeUsageResponse
	if err := json.Unmarshal(body, &resp); err != nil {
		return nil, &APIError{Kind: KindInvalidResponse, Message: err.Error()}
	}
	return &resp, nil
}
