package api

// routes_bankrequests.go: spec 07's P4, POST /api/v1/bank-requests (spec 02
// §7 #74): "Bank with someone else? Tell us" from the website (anonymous,
// source web) and "Another bank? Tell us" from the app (signed in, source app,
// once per bank per account).

import (
	"errors"
	"net/http"
	"strings"
	"time"

	"github.com/google/uuid"

	"github.com/salehtl/hasala/server/internal/banks"
)

// mountBankRequests mounts #74 always: the app's signed-in request (source
// app) needs no website group, so a server without [email] or the auth key
// still records it. The anonymous website request (source web), its CORS
// and its preflight exist only with the website routes (s.Web); without
// them an unauthenticated request is the API's 404.
func (s *Server) mountBankRequests(mux *http.ServeMux) {
	if s.BankUser == nil {
		if s.Web != nil && s.Web.BankUser != nil {
			s.BankUser = s.Web.BankUser
		} else {
			s.BankUser = NewLimiter(bankUserRate, bankUserBurst, publicMaxKeys, s.now)
		}
	}
	web := s.publicRoute(s.handleBankRequest)
	mux.HandleFunc("/api/v1/bank-requests", func(w http.ResponseWriter, r *http.Request) {
		if _, signedIn := bearerToken(r); signedIn && r.Method == http.MethodGet {
			s.requireSession(s.handleBankRequestList)(w, r)
			return
		}
		if s.Web != nil {
			web(w, r)
			return
		}
		if _, signedIn := bearerToken(r); !signedIn {
			writeErr(w, http.StatusNotFound, "not_found", "no such endpoint")
			return
		}
		if r.Method != http.MethodPost {
			w.Header().Set("Allow", "POST")
			writeErr(w, http.StatusMethodNotAllowed, "method_not_allowed", "")
			return
		}
		s.requireSession(s.handleBankRequestSignedIn)(w, r)
	})
}

type bankRequestJSON struct {
	Bank           string `json:"bank"`
	OtherBank      string `json:"otherBank"`
	SenderDomain   string `json:"senderDomain"`
	Source         string `json:"source"`
	Website        string `json:"website"`
	TurnstileToken string `json:"turnstileToken"`
}

func (s *Server) handleBankRequest(w http.ResponseWriter, r *http.Request) {
	if _, signedIn := bearerToken(r); signedIn {
		s.requireSession(s.handleBankRequestSignedIn)(w, r)
		return
	}
	o := s.Web
	if !o.BankIP.Allow(clientKey(r)) || !o.BankGlobal.Allow("") {
		w.Header().Set("Retry-After", "600")
		writeErr(w, http.StatusTooManyRequests, "rate_limited", "")
		return
	}
	var (
		js   bankRequestJSON
		form publicBody
	)
	isForm, ok := decodePublic(w, r, true, &js, &form)
	if !ok {
		return
	}
	if !isForm {
		form = publicBody{Bank: js.Bank, OtherBank: js.OtherBank, Source: js.Source, Website: js.Website,
			TurnstileToken: js.TurnstileToken}
	}
	counted := StatusResponse{Status: "counted"}
	if form.Website != "" {
		o.Honeypot.Add(1)
		s.answerPublic(w, r, isForm, http.StatusAccepted, counted, "", "bank")
		return
	}
	if form.Source != "web" || form.Email != "" || js.SenderDomain != "" {
		s.answerPublic(w, r, isForm, http.StatusBadRequest, nil, "bad_request", "bank")
		return
	}
	s.recordBankRequest(w, r, isForm, form.Bank, form.OtherBank, "", nil)
}

func (s *Server) handleBankRequestSignedIn(w http.ResponseWriter, r *http.Request, userID uuid.UUID) {
	if !s.BankUser.Allow(userID.String()) {
		writeErr(w, http.StatusTooManyRequests, "rate_limited", "")
		return
	}
	var js bankRequestJSON
	if _, ok := decodePublic(w, r, false, &js, nil); !ok {
		return
	}
	if js.Source != "app" || js.Website != "" || js.TurnstileToken != "" {
		writeErr(w, http.StatusBadRequest, "bad_request", "a signed-in request has source app and nothing else")
		return
	}
	domain := ""
	if js.SenderDomain != "" {
		d, err := banks.SenderDomain(js.SenderDomain)
		if err != nil {
			writeErr(w, http.StatusBadRequest, "bad_domain", "")
			return
		}
		domain = d
	}
	s.recordBankRequest(w, r, false, js.Bank, js.OtherBank, domain, &userID)
}

func (s *Server) recordBankRequest(w http.ResponseWriter, r *http.Request, isForm bool, bank, other, domain string, userID *uuid.UUID) {
	other = strings.TrimSpace(other)
	if bank == "" || (bank == "other" && other == "") {
		s.answerPublic(w, r, isForm, http.StatusBadRequest, nil, "bad_bank", "bank")
		return
	}
	choice, err := banks.Resolve(r.Context(), s.Pool, bank, other)
	if errors.Is(err, banks.ErrBadBank) {
		s.answerPublic(w, r, isForm, http.StatusBadRequest, nil, "bad_bank", "bank")
		return
	}
	if err == nil {
		err = banks.Record(r.Context(), s.Pool, choice, userID, domain, s.now())
	}
	switch {
	case errors.Is(err, banks.ErrListFull):
		s.answerPublic(w, r, isForm, http.StatusTooManyRequests, nil, "bank_list_full", "bank")
	case errors.Is(err, banks.ErrBadBank):
		s.answerPublic(w, r, isForm, http.StatusBadRequest, nil, "bad_bank", "bank")
	case err != nil:
		s.logf("api: bank request: %v", err)
		writeErr(w, http.StatusInternalServerError, "internal", "")
	default:
		s.answerPublic(w, r, isForm, http.StatusAccepted, StatusResponse{Status: "counted"}, "", "bank")
	}
}

type BankRequestWire struct {
	Bank        string `json:"bank"`
	Name        string `json:"name"`
	State       string `json:"state"`
	RequestedAt string `json:"requestedAt"`
}

type BankCatalogWire struct {
	Bank  string `json:"bank"`
	Name  string `json:"name"`
	State string `json:"state"`
}

type BankRequestsResponse struct {
	Requests []BankRequestWire `json:"requests"`
	Catalog  []BankCatalogWire `json:"catalog"`
}

func (s *Server) handleBankRequestList(w http.ResponseWriter, r *http.Request, userID uuid.UUID) {
	reqs, err := banks.ForUser(r.Context(), s.Pool, userID)
	if err == nil {
		var list []banks.Entry
		list, err = banks.List(r.Context(), s.Pool)
		if err == nil {
			out := BankRequestsResponse{Requests: []BankRequestWire{}, Catalog: []BankCatalogWire{}}
			for _, q := range reqs {
				out.Requests = append(out.Requests, BankRequestWire{Bank: q.Bank, Name: q.Name, State: q.State,
					RequestedAt: q.RequestedAt.UTC().Format(time.RFC3339)})
			}
			for _, e := range list {
				out.Catalog = append(out.Catalog, BankCatalogWire{Bank: e.Slug, Name: e.Name, State: e.State})
			}
			writeJSON(w, http.StatusOK, out)
			return
		}
	}
	s.logf("api: bank requests: %v", err)
	writeErr(w, http.StatusInternalServerError, "internal", "")
}
