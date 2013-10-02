class AmazonFulfillment
  ActiveMerchant::Fulfillment::AmazonService.class_eval do
    # Used to get an error back if the order doesn't exist, so we can stop endlessly
    # querying.
    def fetch_tracking_raw(oid)
      commit :outbound, :tracking, build_tracking_request(oid, {})
    end

    # See http://www.ruby-forum.com/topic/208730#908342
    def clean_encoding(str)
      # Try it as UTF-8 directly
      str.dup.force_encoding('UTF-8')
    rescue EncodingError
      # Force it to UTF-8, throwing out invalid bits
      str.encode!( 'UTF-8', invalid: :replace, undef: :replace )
    end

    alias_method :orig_parse_response, :parse_response
    def parse_response(service, op, xml)
      # Force UTF-8 encoding
      cxml = clean_encoding(xml)
      resp = orig_parse_response(service, op, cxml)
      if resp.is_a?(Hash) && resp[:success] == ActiveMerchant::Fulfillment::AmazonService::FAILURE && resp.keys.size == 1
        # XML parse error
        Rails.logger.info "*" * 20 + " xml parse error"
        Rails.logger.info cxml
      end
      resp
    end

    # Monkeypatch of the original parse_tracking_response to include carrier, ship date, and arrival time.
    # Changed lines are marked.
    def parse_tracking_response(document)
      response = {}
      response[:tracking_numbers] = {}

      track_node = REXML::XPath.first(document, '//ns1:FulfillmentShipmentPackage/ns1:TrackingNumber')
      if track_node
        id_node = REXML::XPath.first(document, '//ns1:MerchantFulfillmentOrderId')
        response[:tracking_numbers][id_node.text] = track_node.text
        # Changes start here:
        carrier = REXML::XPath.first(document, '//ns1:FulfillmentShipmentPackage/ns1:CarrierCode')
        ship_time = REXML::XPath.first(document, '//ns1:FulfillmentShipment/ns1:ShippingDateTime')
        eta = REXML::XPath.first(document, '//ns1:FulfillmentShipmentPackage/ns1:EstimatedArrivalDateTime')
        response[:fulfillment_info] = {}
        response[:fulfillment_info][id_node.text] = {}
        response[:fulfillment_info][id_node.text][:tracking_number] = track_node.text
        response[:fulfillment_info][id_node.text][:carrier] = carrier.text if carrier
        response[:fulfillment_info][id_node.text][:ship_time] = ship_time.text if ship_time
        response[:fulfillment_info][id_node.text][:eta] = eta.text if eta
        # Changes end here
      end

      response[:response_status] = ActiveMerchant::Fulfillment::AmazonService::SUCCESS
      response
    end
  end

  def initialize(s)
    @shipment = s
  end

  # For Amazon these are the API access key and secret.
  def credentials
    {
      :login    => Spree::Fulfillment.config[:api_key],
      :password => Spree::Fulfillment.config[:secret_key]
    }
  end

  def remote
    @remote ||= ActiveMerchant::Fulfillment::AmazonService.new(credentials)
  end

  def shipping_method
    sm = @shipment.shipping_method
    return 'Standard' unless sm
    case sm.name.downcase
    when /expedited/
      'Expedited'
    when /priority/
      'Priority'
    else
      'Standard'
    end
  end

  def options
    {
      :shipping_method => shipping_method,
      :order_date      => @shipment.order.created_at,
      :comment         => 'Thank you for your order.',
      :email           => @shipment.order.email
    }
  end

  def address
    addr = @shipment.order.ship_address
    {
      :name     => "#{addr.firstname} #{addr.lastname}",
      :address1 => addr.address1,
      :address2 => addr.address2,
      :city     => addr.city,
      :state    => addr.state.abbr,
      :country  => addr.state.country.iso,
      :zip      => addr.zipcode
    }
  end

  def max_quantity_failsafe(n)
    return n unless Spree::Fulfillment.config[:max_quantity_failsafe]
    [Spree::Fulfillment.config[:max_quantity_failsafe], n].min
  end

  def line_items
    skus = @shipment.inventory_units.map do |io|
      sku = io.variant.sku
      raise "missing sku for #{io.variant}" if !sku || sku.empty?
      sku
    end.uniq
    skus.map do |sku|
      num = @shipment.inventory_units.select{|io| io.variant.sku == sku}.size
      { :sku => sku, :quantity => max_quantity_failsafe(num) }
    end
  end

  def ensure_shippable
    # Safety double-check. I think Spree should already enforce this.
    unless @shipment.ready?
      Spree::Fulfillment.log "wrong state: #{@shipment.state}"
      throw :halt
    end
  end

  # Runs inside a state_machine callback. So throwing :halt is how we abort things.
  def fulfill
    Spree::Fulfillment.log "AmazonFulfillment.fulfill start"
    sleep 1   # avoid throttle from Amazon
    ensure_shippable
    num = @shipment.number
    addr = address
    li = line_items
    opts = options
    Spree::Fulfillment.log "#{num}; #{addr}; #{li}; #{opts}"

    begin
      resp = remote.fulfill(num, addr, li, opts)
      Spree::Fulfillment.log "#{resp.params}"
    rescue => e
      Spree::Fulfillment.log "failed - #{e}"
      throw :halt
    end

    # Stop the transition to shipped if there was an error.
    unless resp.success?
      if Spree::Fulfillment.config[:development_mode] && resp.params["faultstring"] =~ /ItemMissingCatalogData/
        # Ignore missing catalog items - can be handy for testing
        Spree::Fulfillment.log "ignoring missing catalog item (test / dev setting - should not see this on prod)"
      else
        Spree::Fulfillment.log "abort - response was in error"
        throw :halt
      end
    end
    Spree::Fulfillment.log "AmazonFulfillment.fulfill end"
  end

  # Returns the tracking number if there is one, else :error if there's a problem with the
  # shipment that will result in a permanent failure to fulfill, else nil.
  def track
    sleep 1   # avoid throttle from Amazon
    Spree::Fulfillment.log "amazon order id #{@shipment.number}"
    resp = remote.fetch_tracking_raw(@shipment.number)
    Spree::Fulfillment.log "#{resp.params}"
    # This can happen, for example, if the SKU doesn't exist.
    return :error if !resp.success? && resp.params["faultstring"] && resp.faultstring["requested order not found"]
    return nil unless resp.params["fulfillment_info"]      # not known yet
    resp.params["fulfillment_info"][@shipment.number]
  end
end
