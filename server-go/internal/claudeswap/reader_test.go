package claudeswap

import (
	"math"
	"testing"
)

const sampleTwoAccounts = `{
  "schemaVersion": 1,
  "activeAccountNumber": 2,
  "accounts": [
    {"number":1,"email":"a@b.com","active":false,"usageStatus":"ok",
     "usage":{"fiveHour":{"pct":7.0,"resetsAt":"2026-07-03T12:00:00.318548+00:00"},
              "sevenDay":{"pct":29.0,"resetsAt":"2026-07-04T18:00:00.000+00:00"}}},
    {"number":2,"email":"c@d.com","active":true,"usageStatus":"ok",
     "usage":{"fiveHour":{"pct":50.0,"resetsAt":"2026-07-03T12:00:00Z"},
              "sevenDay":{"pct":80.0,"resetsAt":"2026-07-04T18:00:00Z"}}}
  ]
}`

func TestParseAccountsConvertsPctAndNormalizesReset(t *testing.T) {
	accts, err := parseAccounts([]byte(sampleTwoAccounts))
	if err != nil {
		t.Fatalf("parse: %v", err)
	}
	if len(accts) != 2 {
		t.Fatalf("len = %d, want 2", len(accts))
	}
	a := accts[0]
	if a.Number != 1 || a.Email != "a@b.com" || a.Active || a.Status != "ok" {
		t.Fatalf("account0 identity wrong: %+v", a)
	}
	if a.FiveHour == nil || math.Abs(a.FiveHour.UsedPct-0.07) > 1e-9 {
		t.Fatalf("5h pct = %v, want 0.07", a.FiveHour)
	}
	if a.FiveHour.ResetsAt == nil || *a.FiveHour.ResetsAt != "2026-07-03T12:00:00.318Z" {
		t.Fatalf("5h reset = %v, want normalized millis Z", a.FiveHour.ResetsAt)
	}
	if accts[1].SevenDay == nil || math.Abs(accts[1].SevenDay.UsedPct-0.80) > 1e-9 {
		t.Fatalf("acct1 7d = %v, want 0.80", accts[1].SevenDay)
	}
}

func TestParseAccountsRejectsWrongSchema(t *testing.T) {
	if _, err := parseAccounts([]byte(`{"schemaVersion":2,"accounts":[]}`)); err == nil {
		t.Fatal("expected error for schemaVersion 2")
	}
}

func TestParseAccountsZeroAccountsIsNilNoError(t *testing.T) {
	accts, err := parseAccounts([]byte(`{"schemaVersion":1,"accounts":[]}`))
	if err != nil {
		t.Fatalf("err = %v, want nil", err)
	}
	if accts != nil {
		t.Fatalf("accts = %v, want nil", accts)
	}
}

func TestParseAccountsNonOKStatusHasNilWindows(t *testing.T) {
	data := `{"schemaVersion":1,"accounts":[
	  {"number":3,"email":"e@f.com","active":false,"usageStatus":"api_key","usage":null}]}`
	accts, err := parseAccounts([]byte(data))
	if err != nil {
		t.Fatalf("parse: %v", err)
	}
	if len(accts) != 1 || accts[0].Status != "api_key" {
		t.Fatalf("status wrong: %+v", accts)
	}
	if accts[0].FiveHour != nil || accts[0].SevenDay != nil {
		t.Fatalf("expected nil windows for api_key account")
	}
}

func TestParseAccountsMalformedJSONErrors(t *testing.T) {
	if _, err := parseAccounts([]byte(`not json`)); err == nil {
		t.Fatal("expected error for malformed json")
	}
}

func TestParseAccountsUnparseableResetDropped(t *testing.T) {
	data := `{"schemaVersion":1,"accounts":[
	  {"number":1,"email":"a@b.com","active":true,"usageStatus":"ok",
	   "usage":{"fiveHour":{"pct":10.0,"resetsAt":"garbage"}}}]}`
	accts, err := parseAccounts([]byte(data))
	if err != nil {
		t.Fatalf("parse: %v", err)
	}
	if accts[0].FiveHour == nil {
		t.Fatal("window should exist even if reset unparseable")
	}
	if accts[0].FiveHour.ResetsAt != nil {
		t.Fatalf("unparseable reset should be nil, got %v", *accts[0].FiveHour.ResetsAt)
	}
	if accts[0].SevenDay != nil {
		t.Fatal("absent sevenDay should be nil")
	}
}
