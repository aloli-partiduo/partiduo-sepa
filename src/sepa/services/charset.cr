# SPDX-License-Identifier: AGPL-3.0-or-later

module Sepa
  # Jeu de caractères restreint des messages SEPA (EPC, « basic Latin ») :
  # lettres sans accent, chiffres, espace et `/ - ? : ( ) . , ' +`. Les
  # textes (noms, adresses, communications) sont translittérés ; les
  # identifiants (référence de bout en bout, RUM, ICS) doivent y être déjà
  # conformes et ne commencent ni ne finissent par `/`, sans `//`
  # (D-SEPA-006). Interne.
  module Charset
    ALLOWED = /\A[A-Za-z0-9\/\-?:().,'+ ]*\z/

    # Lettres que la décomposition Unicode ne ramène pas à une lettre de
    # base, et signes usuels remplacés par un équivalent admis.
    SPECIAL = {
      'ß' => "ss", 'æ' => "ae", 'Æ' => "AE", 'œ' => "oe", 'Œ' => "OE", 'ø' => "o", 'Ø' => "O",
      'đ' => "d", 'Đ' => "D", 'ł' => "l", 'Ł' => "L", 'þ' => "th", 'Þ' => "TH", 'ð' => "d", 'Ð' => "D",
      'ı' => "i", 'ĸ' => "k", 'ŋ' => "n", 'Ŋ' => "N", '&' => "+", '’' => "'", '‘' => "'", '`' => "'",
      '´' => "'", '"' => "'", '«' => "'", '»' => "'", '“' => "'", '”' => "'", '–' => "-", '—' => "-",
      '_' => "-", '\\' => "/", '[' => "(", ']' => ")", '{' => "(", '}' => ")", ';' => ",", '€' => "EUR",
      '#' => "N.", '°' => ".", '*' => ".",
    }

    # Texte conforme : accents retirés (é → e, ç → c), ligatures et signes
    # remplacés, autres caractères changés en espace, espaces réduits,
    # tronqué à `max` caractères.
    def self.transliterate(text : String, max : Int32? = nil) : String
      decomposed = text.unicode_normalize(:nfkd)
      result = String.build do |io|
        decomposed.each_char do |char|
          if replacement = SPECIAL[char]?
            io << replacement
          elsif char.ascii? && ALLOWED.matches?(char.to_s)
            io << char
          elsif char.mark?
            next
          else
            io << ' '
          end
        end
      end
      result = result.gsub(/\s+/, " ").strip
      max ? result[0, max].rstrip : result
    end

    def self.valid?(text : String) : Bool
      ALLOWED.matches?(text)
    end

    # Identifiant SEPA : jeu restreint, 1 à `max` caractères, sans `/` en
    # tête ni en fin, sans `//`, sans espace en tête ni en fin.
    def self.valid_identifier?(text : String, max : Int32 = 35) : Bool
      return false if text.empty? || text.size > max || !valid?(text)
      return false if text.starts_with?('/') || text.ends_with?('/') || text.includes?("//")
      text == text.strip
    end
  end
end
