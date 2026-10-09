# SPDX-License-Identifier: AGPL-3.0-or-later

module Sepa
  module Api
    # Genres de lot (D-SEPA-003). Libellé : `sepa.kinds.<code>`.
    KINDS = %w[transfer debit]

    # Statuts d'un lot (D-SEPA-005). Libellé : `sepa.statuses.<code>`.
    STATUSES = %w[draft prepared approved issued]

    # Modes de validation (D-SEPA-005), mêmes codes que le réglage
    # « validation à deux » de l'administration du parc. Libellé :
    # `sepa.approval_modes.<code>`.
    APPROVAL_MODES = %w[single dual]

    # Règlement à la confirmation de l'émission (D-SEPA-010) : passé ou
    # seulement proposé. Libellé : `sepa.settlement_modes.<code>`.
    SETTLEMENT_MODES = %w[post propose]

    # Mandats (D-SEPA-007). Libellés : `sepa.mandate_kinds.<code>`,
    # `sepa.mandate_statuses.<code>`.
    MANDATE_KINDS    = %w[recurrent one_off]
    MANDATE_STATUSES = %w[active revoked used]

    # Séquences d'un prélèvement SDD Core. Libellé : `sepa.sequences.<code>`.
    SEQUENCES = %w[FRST RCUR OOFF]

    # État du règlement d'un paiement (D-SEPA-010). Libellé :
    # `sepa.settlements.<code>`.
    SETTLEMENTS = %w[none posted elsewhere]

    # Version ISO 20022 des fichiers produits (D-SEPA-001).
    TRANSFER_SCHEMA = "pain.001.001.09"
    DEBIT_SCHEMA    = "pain.008.001.08"

    # Plus grand montant d'un paiement SEPA (999 999 999,99 €).
    MAX_AMOUNT = BigDecimal.new("999999999.99")

    # Nombre de paiements d'un lot.
    MAX_ITEMS = 5000

    # Un mandat récurrent non utilisé pendant 36 mois expire (règlement du
    # SDD Core, D-SEPA-007).
    MANDATE_EXPIRY_MONTHS = 36

    # --- Entrées ---------------------------------------------------------------

    # Réglages du dossier (D-SEPA-005, D-SEPA-010) ; `creditor_identifier` :
    # ICS, exigé pour préparer un lot de prélèvements.
    record SettingsInput,
      approval_mode : String = "single",
      settlement_mode : String = "post",
      batch_booking : Bool = true,
      creditor_identifier : String = "",
      ledger_id : Int64? = nil

    # Lot à composer : genre, journal financier du compte donneur d'ordre
    # (virement) ou créancier (prélèvement), date d'exécution ou d'échéance,
    # libellé ; `batch_booking` : `nil` = celui des réglages.
    record BatchInput,
      kind : String,
      ledger_id : Int64,
      requested_on : Time,
      label : String = "",
      batch_booking : Bool? = nil

    # Paiement saisi ou corrigé dans un lot en préparation. `card_code` :
    # fiche du tiers ; `iban`, `bic`, `name` vides : ceux de la fiche (ou du
    # mandat) ; `amount` : au centime ; `remittance` : communication libre,
    # référence RF ou communication structurée belge.
    record ItemInput,
      card_code : String,
      amount : BigDecimal,
      remittance : String = "",
      iban : String = "",
      bic : String = "",
      name : String = ""

    # Mandat de prélèvement (D-SEPA-007). `rum` vide : générée
    # (`<quick code>-<date>-<rang>`).
    record MandateInput,
      card_code : String,
      signed_on : Time,
      iban : String,
      rum : String = "",
      bic : String = "",
      debtor_name : String = "",
      kind : String = "recurrent"

    # --- Vues ------------------------------------------------------------------

    record SettingsView,
      approval_mode : String,
      settlement_mode : String,
      batch_booking : Bool,
      creditor_identifier : String,
      ledger_id : Int64?,
      stored : Bool do
      def dual? : Bool
        approval_mode == "dual"
      end
    end

    record MandateView,
      id : Int64,
      card_code : String,
      card_name : String?,
      rum : String,
      signed_on : Time,
      debtor_name : String,
      iban : String,
      iban_masked : String,
      bic : String,
      kind : String,
      status : String,
      revoked_on : Time?,
      amended : Bool,
      collection_count : Int32,
      last_collected_on : Time?,
      next_sequence : String?,
      expires_on : Time?,
      in_use : Bool do
      def active? : Bool
        status == "active"
      end

      def kind_key : String
        "sepa.mandate_kinds.#{kind}"
      end

      def status_key : String
        "sepa.mandate_statuses.#{status}"
      end
    end

    # Paiement d'un lot. `card_iban` : IBAN actuel de la fiche (ou du
    # mandat), pour signaler un IBAN changé ; `reference_kind` : `text`,
    # `rf` ou `bba` ; `error` : refus du dernier règlement.
    record ItemView,
      id : Int64,
      batch_id : Int64,
      position : Int32,
      card_code : String,
      name : String,
      iban : String,
      bic : String,
      amount : BigDecimal,
      remittance : String,
      reference_kind : String,
      end_to_end_id : String,
      entry_line_id : Int64?,
      entry_id : Int64?,
      receipt : String,
      due_on : Time?,
      mandate_id : Int64?,
      mandate_rum : String,
      sequence_type : String,
      amended : Bool,
      settlement : String,
      settlement_entry_id : Int64?,
      reversed_entry_id : Int64?,
      card_iban : String?,
      error : Partiduo::Api::FieldError? do
      def iban_differs? : Bool
        card_iban.try { |value| !value.empty? && value != iban } || false
      end

      def posted? : Bool
        settlement == "posted"
      end

      def settlement_key : String
        "sepa.settlements.#{settlement}"
      end
    end

    # Lot, ses paiements et son historique de validation.
    record BatchView,
      id : Int64,
      kind : String,
      ledger_id : Int64,
      ledger_code : String,
      status : String,
      label : String,
      requested_on : Time,
      batch_booking : Bool,
      message_id : String,
      attachment_id : Int64?,
      file_sha256 : String,
      approval_mode : String,
      item_count : Int32,
      total : BigDecimal,
      to_settle_count : Int32,
      created_by_id : Int64?,
      prepared_by_id : Int64?,
      prepared_at : Time?,
      approved_by_id : Int64?,
      approved_at : Time?,
      issued_by_id : Int64?,
      issued_at : Time?,
      issued_on : Time?,
      created_at : Time,
      items : Array(ItemView) do
      def draft? : Bool
        status == "draft"
      end

      def issued? : Bool
        status == "issued"
      end

      def debit? : Bool
        kind == "debit"
      end

      def kind_key : String
        "sepa.kinds.#{kind}"
      end

      def status_key : String
        "sepa.statuses.#{status}"
      end

      def schema : String
        debit? ? DEBIT_SCHEMA : TRANSFER_SCHEMA
      end

      # Nom du fichier produit : `sepa-<genre>-<lot>-<date>.xml`.
      def filename : String
        "sepa-#{debit? ? "prelevements" : "virements"}-#{id}-#{requested_on.to_s("%Y%m%d")}.xml"
      end
    end

    # Écriture ouverte qu'un lot peut régler : facture fournisseur non
    # lettrée (virement) ou facture client non lettrée d'un client sous
    # mandat actif (prélèvement). `iban` : celui de la fiche ou du mandat ;
    # `problem` : clé de ce qui empêcherait le paiement (IBAN absent…).
    record CandidateView,
      line_id : Int64,
      entry_id : Int64,
      card_code : String,
      card_name : String,
      date : Time,
      due_date : Time?,
      ledger_code : String,
      receipt : String?,
      label : String,
      amount : BigDecimal,
      iban : String,
      mandate_id : Int64?,
      problem : String?

    # Bilan du passage des règlements : passés, réglés ailleurs, refusés
    # (avec leur erreur).
    record SettlementReportView, posted : Array(ItemView), elsewhere : Array(ItemView), failed : Array(ItemView)

    # Tuile du tableau de bord : lots à approuver, lots approuvés à émettre,
    # règlements à passer.
    record TileView, to_approve : Int32, to_issue : Int32, to_settle : Int32
  end
end
