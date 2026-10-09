# SPDX-License-Identifier: AGPL-3.0-or-later

# Validation XSD de libxml2 (déjà liée par le module XML de Crystal, d'où
# l'absence d'annotation `Link`) : les quelques fonctions `xmlSchema*` que
# la bibliothèque standard n'expose pas.
lib LibSepaSchema
  fun xmlSchemaNewParserCtxt(url : UInt8*) : Void*
  fun xmlSchemaSetParserStructuredErrors(ctxt : Void*, handler : LibXML::StructuredErrorFunc, data : Void*)
  fun xmlSchemaParse(ctxt : Void*) : Void*
  fun xmlSchemaFreeParserCtxt(ctxt : Void*)
  fun xmlSchemaNewValidCtxt(schema : Void*) : Void*
  fun xmlSchemaSetValidStructuredErrors(ctxt : Void*, handler : LibXML::StructuredErrorFunc, data : Void*)
  fun xmlSchemaValidateDoc(ctxt : Void*, doc : LibXML::Doc*) : Int32
  fun xmlSchemaFreeValidCtxt(ctxt : Void*)
  fun xmlSchemaFree(schema : Void*)
end

module Sepa
  # Validation d'un fichier produit contre le XSD officiel de son message
  # (D-SEPA-012), quand l'exploitant a déposé les schémas
  # (`pain.001.001.09.xsd`, `pain.008.001.08.xsd`) dans le dossier
  # `PARTIDUO_SEPA_XSD_DIR`. Les schémas ISO 20022 ne sont pas embarqués :
  # leurs conditions d'utilisation n'en autorisent pas la redistribution
  # sous AGPL. Sans eux, seul le contrôle structurel (`Structure`) s'applique.
  # Interne.
  module Schema
    ENV_KEY = "PARTIDUO_SEPA_XSD_DIR"

    # Chemin du XSD du message `schema` (`pain.001.001.09`), s'il est déposé.
    def self.path(schema : String, directory : String? = ENV[ENV_KEY]?) : String?
      dir = directory.try(&.strip).presence || return
      file = File.join(dir, "#{schema}.xsd")
      File.file?(file) ? file : nil
    end

    # Erreurs de validation (vide : conforme) ; `nil` si le XSD n'est pas
    # déposé.
    def self.problems(content : String, schema : String, directory : String? = ENV[ENV_KEY]?) : Array(String)?
      file = path(schema, directory) || return
      validate(content, file)
    end

    def self.validate(content : String, xsd : String) : Array(String)
      messages = [] of String
      box = Box.box(messages)
      handler = ->(data : Void*, error : LibXML::Error*) do
        list = Box(Array(String)).unbox(data)
        message = error.null? || error.value.message.null? ? "erreur XSD" : String.new(error.value.message).strip
        line = error.null? ? 0 : error.value.line
        list << (line > 0 ? "ligne #{line} : #{message}" : message)
        nil
      end
      parser = LibSepaSchema.xmlSchemaNewParserCtxt(xsd)
      return ["XSD illisible : #{xsd}"] if parser.null?
      LibSepaSchema.xmlSchemaSetParserStructuredErrors(parser, handler, box)
      schema = LibSepaSchema.xmlSchemaParse(parser)
      LibSepaSchema.xmlSchemaFreeParserCtxt(parser)
      return messages.empty? ? ["XSD illisible : #{xsd}"] : messages if schema.null?
      begin
        document = begin
          XML.parse(content, XML::ParserOptions::NONET)
        rescue ex : XML::Error
          return ["XML illisible : #{ex.message}"]
        end
        validator = LibSepaSchema.xmlSchemaNewValidCtxt(schema)
        begin
          LibSepaSchema.xmlSchemaSetValidStructuredErrors(validator, handler, box)
          status = LibSepaSchema.xmlSchemaValidateDoc(validator, document.to_unsafe.as(LibXML::Doc*))
          messages << "document refusé par le XSD" if status != 0 && messages.empty?
        ensure
          LibSepaSchema.xmlSchemaFreeValidCtxt(validator)
        end
      ensure
        LibSepaSchema.xmlSchemaFree(schema)
      end
      messages
    end
  end
end
