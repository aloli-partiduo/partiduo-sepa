# SPDX-License-Identifier: AGPL-3.0-or-later

require "../spec_helper"

private alias S = Sepa::SpecSupport
private alias Api = Sepa::Api

# Administrateur connecté (profil ADMIN : toutes les permissions), dossier
# provisionné, IBAN de la banque, extension active.
private def signed_in : PartiduoUi::Browser
  browser = PartiduoUi::Books.admin
  S.user("bruno@example.com", "Bruno")
  S.bank_iban(S::BANK_IBAN, S::BANK_BIC)
  S.activate
  browser
end

private def form_body(values : Hash(String, String | Array(String))) : String
  URI::Params.build do |params|
    values.each do |key, value|
      value.is_a?(Array) ? value.each { |item| params.add(key, item) } : params.add(key, value)
    end
  end
end

describe "Écrans des paiements SEPA sous /ext/SEPA/ (ADR-005)" do
  it "est montée sous le code de l'extension, avec ses permissions par route" do
    Marten.routes.reverse("sepa:batches").should eq("/ext/SEPA/batches")
    Marten.routes.reverse("sepa:batch", id: 4).should eq("/ext/SEPA/batches/4")
    mount = PartiduoUi::Extensions["SEPA"]? || raise("interface non montée")
    mount.permission.should eq("sepa.read")
    mount.permission_for("sepa:batches").should eq("sepa.read")
    mount.permission_for("sepa:batch_new").should eq("sepa.prepare")
    mount.permission_for("sepa:item").should eq("sepa.prepare")
    mount.permission_for("sepa:batch_approve").should eq("sepa.approve")
    mount.permission_for("sepa:batch_issue").should eq("sepa.approve")
    mount.permission_for("sepa:mandates").should eq("sepa.read")
    mount.permission_for("sepa:mandate_new").should eq("sepa.admin")
    mount.permission_for("sepa:settings").should eq("sepa.admin")
  end

  it "n'existe pas tant que l'extension est inactive (404) et renvoie un anonyme vers la connexion" do
    browser = PartiduoUi::Books.admin
    browser.get("/ext/SEPA/batches").status.should eq(404)
    S.activate
    response = PartiduoUi::Browser.new.get("/ext/SEPA/batches")
    response.status.should eq(302)
    response.headers["Location"].should eq("/login?next=%2Fext%2FSEPA%2Fbatches")
  end

  it "ouvre un lot de virements, y ajoute les factures, corrige un paiement en HTMX, puis le mène jusqu'aux règlements" do
    browser = signed_in
    S.supplier("Fournitures Alpha", "ALPHA", city: "Lyon")
    invoice = S.purchase("ALPHA", "100", "2026-09-10")
    browser.get("/ext/SEPA/").headers["Location"].should eq("/ext/SEPA/batches")
    browser.get("/ext/SEPA/batches").html.should contain("Aucun lot : ouvrez-en un")

    form = browser.get("/ext/SEPA/batches/new").html
    form.should contain("<h1>Nouveau lot")
    form.should contain(%(value="2026-10-09"))
    refused = browser.post("/ext/SEPA/batches/new", {"kind" => "transfer", "ledger_id" => S.bank.id.to_s,
                                                     "requested_on" => "2026-10-10", "label" => ""})
    refused.status.should eq(422)
    refused.html.should contain("Ce jour n'est pas ouvré pour les paiements SEPA")
    created = browser.post("/ext/SEPA/batches/new", {"kind" => "transfer", "ledger_id" => S.bank.id.to_s,
                                                     "requested_on" => "2026-10-09", "label" => "Fournisseurs",
                                                     "batch_booking" => "1"})
    created.status.should eq(302)
    batch_url = created.headers["Location"]
    page = browser.follow(created).html
    page.should contain("<h1>Lot n°")
    page.should contain("Le lot ne contient aucun paiement.")
    page.should contain("Factures fournisseurs à payer")
    page.should contain(invoice.receipt.to_s)
    line_id = S.line_of(invoice, "ALPHA").id

    added = browser.perform_raw("#{batch_url}/add", form_body({"ids" => [line_id.to_s]}))
    added.status.should eq(302)
    detail = browser.follow(added).html
    detail.should contain("1 paiement ajouté.")
    detail.should contain("FR76 3000 6000 0112 3456 7890 189")
    detail.should contain("Le lot est prêt à être préparé.")
    item = Api.batch(S.system, batch_url.split('/').last.to_i64).items.first

    fragment = browser.htmx_post("/ext/SEPA/items/#{item.id}", {"amount" => "120,00", "remittance" => "Facture n° 2026-77"})
    fragment.status.should eq(200)
    fragment.html.should start_with(%(<tr id="sepa-item-#{item.id}"))
    fragment.html.should contain(%(value="Facture n. 2026-77"))
    over = browser.htmx_post("/ext/SEPA/items/#{item.id}", {"amount" => "130", "remittance" => ""})
    over.status.should eq(422)
    over.html.should contain("Le montant dépasse ce qui reste ouvert")

    prepared = browser.post("#{batch_url}/prepare", {} of String => String)
    prepared_page = browser.follow(prepared).html
    prepared_page.should contain("Lot préparé et soumis : il attend sa décision dans « Approbations ».")
    prepared_page.should contain("data-sepa-approval")
    request = present(Api.approval(S.system, batch_url.split('/').last.to_i64))
    prepared_page.should contain(%(href="/approvals/#{request.id}"))

    # L'approbation se décide dans l'écran commun, après confirmation de
    # l'identité (TOTP) : l'ancienne adresse du lot y renvoie.
    to_common = browser.post("#{batch_url}/approve", {} of String => String)
    to_common.headers["Location"].should eq("/approvals/#{request.id}")
    secret = PartiduoUi::Accounts.enable_totp
    browser.post("/approvals/#{request.id}/approve", {"comment" => ""}).headers["Location"]
      .should eq("/approvals/#{request.id}/reauth")
    browser.post("/approvals/#{request.id}/reauth", {"code" => PartiduoUi::Accounts.totp_code(secret, Time.utc + 30.seconds)})
      .status.should eq(302)
    browser.post("/approvals/#{request.id}/approve", {"comment" => "Vu"}).status.should eq(302)
    approved_page = browser.get(batch_url).html
    approved_page.should contain("Approuvé, à émettre")
    approved_page.should contain("pain.001.001.09")
    approved_page.should contain("Confirmer l'émission")
    file = browser.get("#{batch_url}/file")
    file.status.should eq(200)
    file.headers["Content-Disposition"].should start_with(%(attachment; filename="sepa-virements-))
    file.content.should contain("<Ustrd>Facture n. 2026-77</Ustrd>")

    dashboard = browser.get("/").html
    dashboard.should contain(%(data-pd-count="SEPA_BATCHES">1</span>))
    dashboard.should contain(%(data-module="SEPA"))

    issued = browser.post("#{batch_url}/issue", {"issued_on" => "2026-10-08"})
    issued_page = browser.follow(issued).html
    issued_page.should contain("Émission confirmée ; 1 règlement passé.")
    issued_page.should contain("Règlement passé")
    browser.get("/ext/SEPA/batches?format=csv").content.should contain("Fournisseurs")
  end

  it "gère les mandats et les réglages (sepa.admin)" do
    browser = signed_in
    S.customer("Menuiserie Leroux", "LEROUX")
    browser.get("/ext/SEPA/mandates").html.should contain("Aucun mandat")
    form = browser.get("/ext/SEPA/mandates/new").html
    form.should contain("Référence unique du mandat (RUM)")
    refused = browser.post("/ext/SEPA/mandates/new", {"card_code" => "LEROUX", "signed_on" => "2026-01-15",
                                                      "iban" => "BE68 5390 0754 7035", "kind" => "recurrent"})
    refused.status.should eq(422)
    refused.html.should contain("IBAN invalide")
    created = browser.post("/ext/SEPA/mandates/new", {"card_code" => "LEROUX", "signed_on" => "2026-01-15",
                                                      "iban" => "BE68 5390 0754 7034", "kind" => "recurrent"})
    created.status.should eq(302)
    list = browser.follow(created).html
    list.should contain("Mandat LEROUX-20260115-1 enregistré.")
    list.should contain("BE68 **** **** 7034")
    list.should contain("Premier (FRST)")

    # L'ICS et la validation sont ceux de la société : rappelés, avec un
    # lien vers sa configuration ; plus de champ propre à l'extension.
    S.company(creditor_identifier: S::ICS, approval_mode: "dual")
    settings = browser.get("/ext/SEPA/settings").html
    settings.should contain("L'identifiant créancier SEPA (ICS) de la société : #{S::ICS} ; validation des lots : Deux personnes.")
    settings.should contain(%(href="/settings/company/edit"))
    settings.should_not contain(%(name="creditor_identifier"))
    settings.should_not contain(%(name="approval_mode"))
    bad = browser.post("/ext/SEPA/settings", {"settlement_mode" => "never", "ledger_id" => ""})
    bad.status.should eq(422)
    saved = browser.post("/ext/SEPA/settings", {"settlement_mode" => "propose", "ledger_id" => S.bank.id.to_s,
                                                "batch_booking" => "1"})
    saved.status.should eq(302)
    Api.settings(S.system).settlement_mode.should eq("propose")
    Api.settings(S.system).dual?.should be_true
    Api.settings(S.system).creditor_identifier.should eq(S::ICS)
  end

  it "refuse la composition et l'approbation à qui ne peut que consulter (403)" do
    PartiduoUi::Reference.provision
    PartiduoUi::Reference.fiscal_year(2026)
    profile = PartiduoUi::Accounts.profile("Lecture SEPA", ["sepa.read", "accounting.ledger.read"])
    PartiduoUi::Accounts.create(profile: nil, profile_id: profile)
    S.activate
    browser = PartiduoUi::Accounts.signed_in
    browser.get("/ext/SEPA/batches").status.should eq(200)
    browser.get("/ext/SEPA/batches/new").status.should eq(403)
    browser.get("/ext/SEPA/settings").status.should eq(403)
    browser.get("/ext/SEPA/mandates").status.should eq(200)
  end
end
