# Copyright (c) 2007 Joseph Jaramillo
# 
# Permission is hereby granted, free of charge, to any person obtaining a copy
# of this software and associated documentation files (the "Software"), to deal
# in the Software without restriction, including without limitation the rights
# to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
# copies of the Software, and to permit persons to whom the Software is
# furnished to do so, subject to the following conditions:
# 
# The above copyright notice and this permission notice shall be included in
# all copies or substantial portions of the Software.
# 
# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
# IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
# FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
# AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
# LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
# OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
# THE SOFTWARE.

module Fedex #:nodoc:
  
  class MissingInformationError < StandardError; end #:nodoc:
  class FedexError < StandardError; end #:nodoc
  
  # Provides access to Fedex Web Services
  class Base
    
    # Defines the required parameters for various methods
    REQUIRED_OPTIONS = {
      :base        => [ :auth_key, :security_code, :account_number, :meter_number ],
      :price       => [ :shipper, :recipient, :weight ],
      :label       => [ :shipper, :recipient, :weight, :service_type ],
      :labels      => [ :shipper, :recipient, :service_type ],
      :contact     => [ :name, :phone_number ],
      :address     => [ :country, :street, :city, :state, :zip ],
      :ship_cancel => [ :tracking_number ],
      :intl        => [ :customs_value, :packages ]
    }
    
    # Defines the relative path to the WSDL files.  Defaults assume lib/wsdl under plugin directory.
    WSDL_PATHS = {
      :rate => 'wsdl/RateService_v7.wsdl',
      :ship => 'wsdl/ShipService_v7.wsdl',
    }
    
    # Defines the Web Services version implemented.
    WS_VERSION = { :Major => 7, :Intermediate => 0, :Minor => 0 }
    
    SUCCESSFUL_RESPONSES = ['SUCCESS', 'WARNING', 'NOTE'] #:nodoc:
    
    DIR = File.dirname(__FILE__)
    
    attr_accessor :auth_key,
                  :security_code,
                  :account_number,
                  :meter_number,
                  :dropoff_type,
                  :service_type,
                  :units,
                  :packaging_type,
                  :sender,
                  :debug,
                  :environment
    
    # Initializes the Fedex::Base class, setting defaults where necessary.
    # 
    #  fedex = Fedex::Base.new(options = {})
    #
    # === Example:
    #   fedex = Fedex::Base.new(:auth_key       => AUTH_KEY,
    #                           :security_code  => SECURITY_CODE
    #                           :account_number => ACCOUNT_NUMBER,
    #                           :meter_number   => METER_NUMBER)
    #
    # === Required options for new
    #   :auth_key       - Your Fedex Authorization Key
    #   :security_code  - Your Fedex Security Code
    #   :account_number - Your Fedex Account Number
    #   :meter_number   - Your Fedex Meter Number
    #
    # === Additional options
    #   :dropoff_type       - One of Fedex::DropoffTypes.  Defaults to DropoffTypes::REGULAR_PICKUP
    #   :packaging_type     - One of Fedex::PackagingTypes.  Defaults to PackagingTypes::YOUR_PACKAGING
    #   :label_type         - One of Fedex::LabelFormatTypes.  Defaults to LabelFormatTypes::COMMON2D.  You'll only need to change this
    #                         if you're generating completely custom labels with a format of your own design.  If printing to Fedex stock
    #                         leave this alone.
    #   :label_image_type   - One of Fedex::LabelSpecificationImageTypes.  Defaults to LabelSpecificationImageTypes::PDF.
    #   :label_stock_type   - One of Fedex::LabelStockTypes.  Defaults to LabelStockTypes::PAPER_85X11_TOP_HALF_LABEL.
    #   :rate_request_type  - One of Fedex::RateRequestTypes.  Defaults to RateRequestTypes::ACCOUNT
    #   :payment            - One of Fedex::PaymentTypes.  Defaults to PaymentTypes::SENDER
    #   :units              - One of Fedex::WeightUnits.  Defaults to WeightUnits::LB
    #   :currency           - One of Fedex::CurrencyTypes.  Defaults to CurrencyTypes::USD
    #   :debug              - Enable or disable debug (wiredump) output.  Defaults to false.
    #   :environment        - Connect to production or development FedEx servers. Defaults to production if RAILS_ENV == production, 
    #                         else development
    def initialize(options = {})
      check_required_options(:base, options)
      
      @auth_key           = options[:auth_key]
      @security_code      = options[:security_code]
      @account_number     = options[:account_number]
      @meter_number       = options[:meter_number]
                        
      @dropoff_type       = options[:dropoff_type]      || DropoffTypes::REGULAR_PICKUP
      @packaging_type     = options[:packaging_type]    || PackagingTypes::YOUR_PACKAGING
      @label_type         = options[:label_type]        || LabelFormatTypes::COMMON2D
      @label_image_type   = options[:label_image_type]  || LabelSpecificationImageTypes::PDF
      @label_stock_type   = options[:label_stock_type]  || LabelStockTypes::PAPER_85X11_TOP_HALF_LABEL
      @rate_request_type  = options[:rate_request_type] || RateRequestTypes::LIST
      @payment_type       = options[:payment]           || PaymentTypes::SENDER
      @units              = options[:units]             || WeightUnits::LB
      @currency           = options[:currency]          || CurrencyTypes::USD
      @debug              = options[:debug]             || false
      @wiredump           = options[:wiredump]          || STDOUT
      @environment        = options[:environment]       || (defined?(RAILS_ENV) && 'production' == RAILS_ENV ? 'production' : 'development')
      @environment        = @environment.to_sym
      
      set_international_option_defaults(options)  if international_shipment?(options)
    end
    
    # Gets a rate quote from Fedex.
    #
    #   fedex = Fedex::Base.new(options)
    #   
    #   single_price = fedex.price(
    #     :shipper => { ... },
    #     :recipient => { ... },
    #     :weight => 1,
    #     :service_type => 'STANDARD_OVERNIGHT'
    #   }
    #   single_price #=> 1315
    #
    #   multiple_prices = fedex.price(
    #     :shipper => { ... },
    #     :recipient => { ... },
    #     :weight => 1
    #   )
    #   multiple_prices #=> { 'STANDARD_OVERNIGHT' => 1315, 'PRIORITY_OVERNIGHT' => 2342, ... }
    #
    # === Required options for price
    #   :shipper              - A hash containing contact information and an address for the shipper.  (See below.)
    #   :recipient            - A hash containing contact information and an address for the recipient.  (See below.)
    #   :weight               - The total weight of the shipped package.
    #
    # === Optional options
    #   :count                - How many packages are in the shipment. Defaults to 1.
    #   :service_type         - One of Fedex::ServiceTypes. If not specified, Fedex gives you rates for all
    #                           of the available service types (and you will receive a hash of prices instead of a
    #                           single price).
    #
    # === Address format
    # The 'shipper' and 'recipient' address values should be hashes. Like this:
    #
    #  address = {
    #    :country => 'US',
    #    :street => '1600 Pennsylvania Avenue NW'
    #    :city => 'Washington',
    #    :state => 'DC',
    #    :zip => '20500'
    #  }
    def price(options = {})
      puts options.inspect if $DEBUG

      # Check overall options
      check_required_options(:price, options)

      # Check Address Options
      check_required_options(:contact, options[:shipper][:contact])
      check_required_options(:address, options[:shipper][:address])
      check_two_letter_country_code(:shipper, options)

      # Check Contact Options
      check_required_options(:contact, options[:recipient][:contact])
      check_required_options(:address, options[:recipient][:address])
      check_two_letter_country_code(:recipient, options)

      # Build shipment options
      options = build_shipment_options(:crs, options) 

      # Process the rate request 
      driver = create_driver(:rate)
      result = driver.getRates(options)

      extract_price = proc do |reply_detail|
        shipment_details = reply_detail.ratedShipmentDetails
        price = nil
        for shipment_detail in shipment_details
          rate_detail = shipment_detail.shipmentRateDetail
          if rate_detail.rateType == "PAYOR_#{@rate_request_type}"
            price = (rate_detail.totalNetCharge.amount.to_f * 100).to_i
            break
          end
        end
        if price
          return price
        else
          raise "Couldn't find Fedex price in response!"
        end
      end

      msg = error_msg(result, false)
      if successful?(result) && msg !~ /There are no valid services available/
        reply_details = result.rateReplyDetails
        if reply_details.respond_to?(:ratedShipmentDetails)
          price = extract_price.call(reply_details)
          service_type ? price : { reply_details.serviceType => price }
        else
          reply_details.inject({}) {|h,r| h[r.serviceType] = extract_price.call(r); h }
        end
      else
        raise FedexError.new("Unable to retrieve price from Fedex: #{msg}")
      end
    end

    # Generate a new shipment and return associated data, including price, tracking number, and the label itself.
    #
    #  fedex = Fedex::Base.new(options)
    #  price, label, tracking_number = fedex.label(fields)
    #
    # Returns the actual price for the label, the Base64-decoded label in the format specified in Fedex::Base,
    # and the tracking_number for the shipment.
    #
    # === Required options for label
    #   :shipper      - A hash containing contact information and an address for the shipper.  (See below.)
    #   :recipient    - A hash containing contact information and an address for the recipient.  (See below.)
    #   :weight       - The total weight of the shipped package.
    #   :service_type - One of Fedex::ServiceTypes
    #
    # === Address format
    # The 'shipper' and 'recipient' address values should be hashes. Like this:
    #
    #  shipper = {:contact => {:name => 'John Doe',
    #                          :phone_number => '4805551212'},
    #             :address => address} # See "Address" for under price.
    def label(options = {})
      multiple = options[:packages] && options[:packages].length > 1      
      options[:weight] ||= options[:packages].first[:weight] if options[:packages] && options[:packages].length == 1

      check_shipping_options(options, multiple ? :labels : :label)
      
      # Build shipment options
      options = build_shipment_options(:ship, options, :master => multiple)

      unless multiple
        # Process the shipment request
        process_shipment(options)  
      else
        # Process multiple shipments
        charge, label, master_tracking_number = process_shipment(options)
        labels = [label]

        options[:packages].each_with_index do |package, idx|
          options = build_shipment_options(:ship, options, :package => package, :sequence => idx + 1)
          charge, label, tracking_number = process_shipment(options)
          labels << label
        end

        [charge, labels, master_tracking_number]
      end
    end


    def check_shipping_options(options, label_or_labels)
      puts options.inspect if $DEBUG

      # Check overall options
      check_required_options(label_or_labels, options)

      # Check Address Options
      check_required_options(:contact, options[:shipper][:contact])
      check_required_options(:address, options[:shipper][:address])
      check_two_letter_country_code(:shipper, options)

      # Check Contact Options
      check_required_options(:contact, options[:recipient][:contact])
      check_required_options(:address, options[:recipient][:address])
      check_two_letter_country_code(:recipient, options)
    end

    def process_shipment(options)
      driver = create_driver(:ship)
      result = driver.processShipment(options)
      successful = successful?(result)

      msg = error_msg(result, false)
      if successful && msg !~ /There are no valid services available/
        pre = result.completedShipmentDetail.shipmentRating.shipmentRateDetails
        charge = ((pre.class == Array ? pre[0].totalNetCharge.amount.to_f : pre.totalNetCharge.amount.to_f) * 100).to_i
        tracking_number = result.completedShipmentDetail.completedPackageDetails.trackingIds.trackingNumber
        label = Base64.decode64(result.completedShipmentDetail.completedPackageDetails.label.parts.image)        
        [charge, labels, tracking_number]
      else
        raise FedexError.new("Unable to get label from Fedex: #{msg}")
      end
    end
    

    # Cancel a shipment
    #
    #  fedex = Fedex::Base.new(options)
    #  result = fedex.cancel(options)
    #
    # Returns a boolean indicating whether or not the operation was successful
    #
    # === Required options for cancel
    #   :tracking_number - The Fedex-provided tracking number you wish to cancel
    def cancel(options = {})
      check_required_options(:ship_cancel, options)

      tracking_number = options[:tracking_number]
      #carrier_code    = options[:carrier_code] || carrier_code_for_tracking_number(tracking_number)

      driver = create_driver(:ship)

      result = driver.deleteShipment(common_options(:ship).merge(
        :TrackingNumber => tracking_number
      ))

      return successful?(result)
    end

    private

    # Options that go along with each request
    # service - :crs or :ship
    def common_options(service)
      {
        :WebAuthenticationDetail => { :UserCredential => { :Key => @auth_key, :Password => @security_code } },
        :ClientDetail => { :AccountNumber => @account_number, :MeterNumber => @meter_number },
        :Version => WS_VERSION.merge({:ServiceId => service.to_s})
      }
    end

    # Checks the supplied address to ensure the country is a two-letter code
    def check_two_letter_country_code(type, options)
      return true if 2 == options[type][:address][:country].length
      
      err_msg = "Country '#{options[type][:address][:country]}' must be provided as a two-letter ISO country code"
      raise MissingInformationError.new("Error in #{type.to_s.humanize} Address: #{err_msg}")
    end

    # Checks the supplied options for a given method or field and throws an exception if anything is missing
    def check_required_options(option_set_name, options = {})
      required_options = REQUIRED_OPTIONS[option_set_name]
      missing = []
      required_options.each{|option| missing << option if options.nil? || options[option].nil?}

      unless missing.empty?
        raise MissingInformationError.new("Missing #{missing.collect{|m| ":#{m}"}.join(', ')} for #{option_set_name}")
      end
    end

    # Creates and returns a driver for the requested action
    def create_driver(name)
      path = File.expand_path(DIR + '/' + WSDL_PATHS[name])
      
      raise MissingInformationError.new("Missing WSDL file at #{path}") unless File.exists?(path)
            
      wsdl = SOAP::WSDLDriverFactory.new(path)
      driver = wsdl.create_rpc_driver
      driver.proxy.endpoint_url = if :production == @environment then "https://gateway.fedex.com:443/web-services"
      else "https://gatewaybeta.fedex.com:443/web-services"
      end
      
      # /s+(1000|0|9c9|fcc)\s+/ => ""
      driver.wiredump_dev = @wiredump if @debug

      driver
    end

    # Resolves the ground+residential discrepancy.  If a package is shipped
    # via Fedex Groundto an address marked as residential the service type must
    # be set to ServiceTypes::GROUND_HOME_DELIVERY and not ServiceTypes::FEDEX_GROUND.
    def resolve_service_type(service_type, residential)
      if residential && (service_type == ServiceTypes::FEDEX_GROUND)
        ServiceTypes::GROUND_HOME_DELIVERY
      else
        service_type
      end
    end

    # Returns a boolean determining whether a request was successful.
    def successful?(result)
      if defined?(result.cancelPackageReply)
        SUCCESSFUL_RESPONSES.any? {|r| r == result.cancelPackageReply.highestSeverity }
      else
        SUCCESSFUL_RESPONSES.any? {|r| r == result.highestSeverity }
      end
    end

    # Returns the error message contained in the SOAP response, if one exists.
    def error_msg(result, return_nothing_if_successful=true)
      return "" if successful?(result) && return_nothing_if_successful
      notes = result.notifications
      notes.respond_to?(:message) ? notes.message : notes.first.message
    end

    # Attempts to determine the carrier code for a tracking number based upon its length.
    # Currently supports Fedex Ground and Fedex Express
    def carrier_code_for_tracking_number(tracking_number)
      case tracking_number.length
      when 12
        'FDXE'
      when 15
        'FDXG'
      end
    end

    def build_shipment_options(service, options, toggles)
      # Prepare variables
      order_number        = options[:order_number] || ''

      shipper             = options[:shipper]
      recipient           = options[:recipient]

      shipper_contact     = shipper[:contact]
      shipper_address     = shipper[:address]

      recipient_contact   = recipient[:contact]
      recipient_address   = recipient[:address]

      count               = options[:count] || (options[:packages] ? options[:packages].length : 1)
      weight              = options[:packages] ? options[:packages].sum{|p| p[:weight]} : options[:weight]

      time                = options[:time] || Time.now
      time                = time.to_time.iso8601 if time.is_a?(Time)

      residential         = !!recipient_address[:residential]

      service_type        = options[:service_type]
      service_type        = resolve_service_type(service_type, residential) if service_type

      common_options(service||:crs).merge(
        :RequestedShipment => {
          :Shipper => {
            :Contact => {
              :PersonName => shipper_contact[:name],
              :PhoneNumber => shipper_contact[:phone_number]
            },
            :Address => {
              :CountryCode => shipper_address[:country],
              :StreetLines => shipper_address[:street],
              :City => shipper_address[:city],
              :StateOrProvinceCode => shipper_address[:state],
              :PostalCode => shipper_address[:zip]
            }
          },
          :Recipient => {
            :Contact => {
              :PersonName => recipient_contact[:name],
              :PhoneNumber => recipient_contact[:phone_number]
            },
            :Address => {
              :CountryCode => recipient_address[:country],
              :StreetLines => recipient_address[:street],
              :City => recipient_address[:city],
              :StateOrProvinceCode => recipient_address[:state],
              :PostalCode => recipient_address[:zip],
              :Residential => residential
            }
          },
          :ShippingChargesPayment => {
            :PaymentType => @payment_type,
            :Payor => {
              :AccountNumber => @account_number,
              :CountryCode => shipper_address[:country]
            }
          },
          :LabelSpecification => {
            :LabelFormatType => @label_type,
            :ImageType => @label_image_type,
            :LabelStockType => @label_stock_type
          },
          :RateRequestTypes => @rate_request_type,
          :PackageCount => count,
          :ShipTimestamp => time,
          :DropoffType => @dropoff_type,
          :ServiceType => service_type,
          :PackagingType => @packaging_type,
          :PackageDetail => RequestedPackageDetailTypes::INDIVIDUAL_PACKAGES,
          :PackageDetailSpecified => true,
          :TotalWeight => { :Units => @units, :Value => weight },
          :PreferredCurrency => @currency,
          :RequestedPackageLineItems => package_line_items(options[:packages] ? options[:packages] : options)
        }
      ).merge(
        international_shipment?(options) ? international_shipping_options(options) : {}
      )
    end
    
    def international_shipment?(options)
      return nil unless options[:shipper] && options[:shipper][:address]
      return nil unless options[:recipient] && options[:recipient][:address]
      
      shipper_country_is_usa     = options[:shipper][:address][:country][/us/i]
      recipient_country_is_usa   = options[:recipient][:address][:country][/us/i]
      
      !shipper_country_is_usa || !recipient_country_is_usa
    end
    
    # Return the options required for shipping internationally
    def international_shipping_options(options)
      {
        :InternationalDocumentContentType => @intl[:content_type],
        :AdmissibilityPackageType => @intl[:admissibility_package_type],
        :RequestedShipment => {
          :ShipTimeStamp => Time.now.iso8601,
          :Date => Date.today,
        },
        :TermsOfSale => @intl[:terms_of_sale],
        :FreightCharge => @intl[:freight_charge],
        :InsuranceCharge => @intl[:insurance_charge],
        :RegulatoryControlType => @intl[:regulator_control_type],
        :CustomsValue => @intl[:customs_value],
        :Purpose => @intl[:purpose],
        :Commodity => {
          :NumberOfPieces => 1,
          :Description => options[:commodity][:description],
          :CountryOfManufacture => options[:commodity][:country_of_manufacture],
          :Quantity => options[:commodity][:quantity],
          :Units => options[:commodity][:units],
          :Weight => options[:weight],
          :UnitPrice => options[:unit_price],
          :Amount => options[:unit_price] * options[:units],
        }
      }
    end
    

    # Date.today format
    ### allow passing in multiple items (commodities?) and doing MPS stuff (since each commod needs own data anyway)
    ### raise missing info errors if needed not passed for itnernational    
    def set_international_option_defaults(options)
      check_required_options(:intl, options)

      @intl = {}
      @intl[:content_type]                = options[:international_document_content_type]   ||  InternationalDocumentContentTypes::NON_DOCUMENTS
      @intl[:admissibility_package_type]  = options[:admissibility_package_type]            ||  AdmissibilityPackageTypes::BOX # "Other packaging"
      @intl[:terms_of_sale]	              = options[:terms_of_sale]                         ||  TermsOfSaleTypes::FOB_OR_FCA # default, shipper pays
      @intl[:freight_charge]	            = options[:freight_charge]                        ||  0
      @intl[:insurance_charge]	          = options[:insurance_charge]                      ||  0
      @intl[:regulatory_control_type]	    = options[:regulatory_control_type]               ||  nil
      @intl[:purpose]	                    = options[:purpose]                               ||  PurposeOfShipmentTypes::SOLD
      @intl[:customs_value]	              = options[:customs_value]
    end
    
    def package_line_items(packages)
      line_items = []
      (packages.is_a?(Array) ? packages : [packages]).each_with_index do |package, idx|
        line_item = {
          :SequenceNumber => idx + 1,
          :Weight => {
            :Units => @units,
            :Value => package[:weight]
          },
          :SpecialServicesRequested => {
            :SpecialServiceTypes => []
          }
        }
      
        if package[:dry_ice]
          dry_ice_type = package[:dry_ice_type] || PackageSpecialServiceTypes::DRY_ICE
          line_item[:SpecialServicesRequested][:SpecialServiceTypes] << dry_ice_type

          line_item[:SpecialServicesRequested].merge!(
            :DryIceWeight => {
              :Units => package[:dry_ice_weight_units] || WeightUnits::KG,
              :Value => package[:dry_ice_weight]
            }
          )
        end
        
        if package[:dangerous_goods]
          dangerous_goods_type = package[:dangerous_goods_type] || PackageSpecialServiceTypes::DANGEROUS_GOODS
          line_item[:SpecialServicesRequested][:SpecialServiceTypes] << dangerous_goods_type

          line_item[:SpecialServicesRequested].merge!(
            :DangerousGoodsDetail => {
              :Accessibility => package[:dangerous_goods_accessibility] || DangerousGoodsAccessibilityTypes::INACCESSIBLE
            }
          )
        end
        
        line_items << line_item
      end
      
      line_items
    end

  end
end
