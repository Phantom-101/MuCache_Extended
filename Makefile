GO      = /usr/local/go/bin/go
GOFLAGS =
BINDIR  = bin

CHAIN_SERVICES = service1 service2 service3 service4 backend
HOTEL_SERVICES = frontend search rate profile reservation user
BOUTIQUE_SERVICES = frontend cart checkout currency email payment product_catalog recommendations shipping

.PHONY: all chain hotel boutique clean

all: chain hotel boutique

# ── chain benchmark ────────────────────────────────────────────────────────────

chain: $(addprefix $(BINDIR)/chain_,\
	$(addsuffix _http,  $(CHAIN_SERVICES)) \
	$(addsuffix _flame, $(CHAIN_SERVICES)))

$(BINDIR)/chain_%_http:
	@mkdir -p $(BINDIR)
	$(GO) build $(GOFLAGS) -o $@ ./cmd/chain/$*

$(BINDIR)/chain_%_flame:
	@mkdir -p $(BINDIR)
	$(GO) build $(GOFLAGS) -tags flame -o $@ ./cmd/chain/$*

# ── hotel benchmark ────────────────────────────────────────────────────────────

hotel: $(addprefix $(BINDIR)/hotel_,\
	$(addsuffix _http,  $(HOTEL_SERVICES)) \
	$(addsuffix _flame, $(HOTEL_SERVICES)))

$(BINDIR)/hotel_%_http:
	@mkdir -p $(BINDIR)
	$(GO) build $(GOFLAGS) -o $@ ./cmd/hotel/$*

$(BINDIR)/hotel_%_flame:
	@mkdir -p $(BINDIR)
	$(GO) build $(GOFLAGS) -tags flame -o $@ ./cmd/hotel/$*

# ── boutique benchmark ─────────────────────────────────────────────────────────

boutique: $(addprefix $(BINDIR)/boutique_,\
	$(addsuffix _http,  $(BOUTIQUE_SERVICES)) \
	$(addsuffix _flame, $(BOUTIQUE_SERVICES)))

$(BINDIR)/boutique_%_http:
	@mkdir -p $(BINDIR)
	$(GO) build $(GOFLAGS) -o $@ ./cmd/boutique/$*

$(BINDIR)/boutique_%_flame:
	@mkdir -p $(BINDIR)
	$(GO) build $(GOFLAGS) -tags flame -o $@ ./cmd/boutique/$*

clean:
	rm -rf $(BINDIR)
