class Application
  class Person
    attr_reader :person_id, :person_attributes
    attr_accessor :relationships

    def initialize(person_id, person_attributes)
      @person_id = person_id
      @person_attributes = person_attributes
      @relationships = []
    end
  end

  class Applicant < Person
    attr_reader :applicant_id, :applicant_attributes
    attr_accessor :outputs

    def initialize(person_id, person_attributes, applicant_id, applicant_attributes)
      @person_id = person_id
      @person_attributes = person_attributes
      @applicant_id = applicant_id
      @applicant_attributes = applicant_attributes
      @outputs = {}
    end
  end

  class Relationship
    attr_reader :person, :relationship, :relationship_attributes

    def initialize(person, relationship, relationship_attributes)
      @person = person
      @relationship = relationship
      @relationship_attributes = relationship_attributes
    end
  end

  class Household
    attr_reader :household_id, :people

    def initialize(household_id, people)
      @household_id = household_id
      @people = people
    end
  end

  class TaxReturn
    attr_reader :filers, :dependents

    def initialize(filers, dependents)
      @filers = filers
      @dependents = dependents
    end
  end

  class TaxPerson
    attr_reader :person

    def initialize(person)
      @person = person
    end
  end

  attr_reader :state, :applicants, :people, :physical_households, :tax_households, :medicaid_households, :tax_returns, :config

  XML_NAMESPACES = {
    "exch"     => "http://at.dsh.cms.gov/exchange/1.0",
    "s"        => "http://niem.gov/niem/structures/2.0", 
    "ext"      => "http://at.dsh.cms.gov/extension/1.0",
    "hix-core" => "http://hix.cms.gov/0.1/hix-core", 
    "hix-ee"   => "http://hix.cms.gov/0.1/hix-ee",
    "nc"       => "http://niem.gov/niem/niem-core/2.0", 
    "hix-pm"   => "http://hix.cms.gov/0.1/hix-pm",
    "scr"      => "http://niem.gov/niem/domains/screening/2.1"
  }

  def initialize(raw_application, return_application)
    @raw_application = raw_application
    @xml_application = Nokogiri::XML(raw_application) do |config|
      config.default_xml.noblanks
    end
    @determination_date = Date.today
    @return_application = return_application
  end

  def result
    read_xml!
    read_configs!

    process_rules!
    #to_hash
    to_xml
  end

  private

  def validate
  end

  def get_node(xpath, start_node=@xml_application)
    start_node.at_xpath(xpath, XML_NAMESPACES)
  end

  def get_nodes(xpath, start_node=@xml_application)
    start_node.xpath(xpath, XML_NAMESPACES)
  end

  def find_or_create_node(node, xpath)
    xpath = xpath.gsub(/^\/+/,'')
    if xpath.empty?
      node
    elsif get_node(xpath, node)
      get_node(xpath, node)
    else
      xpath_list = xpath.split('/')
      next_node = get_node(xpath_list.first, node)
      if next_node
        find_or_create_node(next_node, xpath_list[1..-1].join('/'))
      else
        Nokogiri::XML::Builder.with(node) do |xml|
          xml.send(xpath_list.first)
        end

        find_or_create_node(get_node(xpath_list.first, node), xpath_list[1..-1].join('/'))
      end
    end
  end

  def return_application?
    @return_application
  end

  def read_configs!
    config = MedicaidEligibilityApi::Application.options[:state_config]
    if config[@state]
      @config = config[:default].merge(config[@state])
    else
      @config = config[:default]
    end
    @config.merge!(MedicaidEligibilityApi::Application.options[:system_config])
  end

  def read_xml!
    @people = []
    @applicants = []
    @state = get_node("/exch:AccountTransferRequest/ext:TransferHeader/ext:TransferActivity/ext:RecipientTransferActivityStateCode").inner_text
    
    xml_people = get_nodes "/exch:AccountTransferRequest/hix-core:Person"
    
    for xml_person in xml_people
      person_id = xml_person.attribute('id').value
      person_attributes = {}

      xml_app = get_nodes("/exch:AccountTransferRequest/hix-ee:InsuranceApplication/hix-ee:InsuranceApplicant").find{
        |x_app| x_app.at_xpath("hix-core:RoleOfPersonReference").attribute('ref').value == person_id
      }
      if xml_app
        applicant_id = xml_app.attribute('id').value
        applicant_attributes = {}
      end
      
      for input in ApplicationVariables::PERSON_INPUTS
        if input[:xml_group] == :person
          node = xml_person.at_xpath(input[:xpath])
        elsif input[:xml_group] == :applicant
          unless xml_app
            next
          end
          node = xml_app.at_xpath(input[:xpath])
        elsif input[:xml_group] == :relationship
          next
        else
          raise "Variable #{input[:name]} has unimplemented xml group #{input[:xml_group]}"
        end

        attr_value = get_xml_variable(node, input, person_id)
        
        if input[:xml_group] == :person
          person_attributes[input[:name]] = attr_value
        elsif input[:xml_group] == :applicant
          applicant_attributes[input[:name]] = attr_value
        end
      end

      if xml_app
        person = Applicant.new(person_id, person_attributes, applicant_id, applicant_attributes)
        @applicants << person
      else
        person = Person.new(person_id, person_attributes)
      end
      @people << person
    end

    # get relationships
    for person in @people
      xml_person = get_nodes("/exch:AccountTransferRequest/hix-core:Person").find{
        |x_person| x_person.attribute('id').value == person.person_id
      }
      relationships = get_nodes("hix-core:PersonAugmentation/hix-core:PersonAssociation", xml_person)

      for relationship in relationships
        other_id = get_node("nc:PersonReference", relationship).attribute('ref').value
        
        other_person = @people.find{|p| p.person_id == other_id}
        relationship_code = get_node("hix-core:FamilyRelationshipCode", relationship).inner_text
        relationship_attributes = {}
        for input in ApplicationVariables::PERSON_INPUTS.select{|i| i.group == :relationship}
          node = get_node(input[:xpath], relationship)

          relationship_attributes[input[:name]] = get_xml_variable(node, input, person_id)
        end

        person.relationships << Relationship.new(other_person, relationship_code, relationship_attributes)
      end
    end

    # get tax returns
    @tax_returns = []
    xml_tax_returns = get_nodes("/exch:AccountTransferRequest/hix-ee:TaxReturn")
    for xml_return in xml_tax_returns
      filers = []
      xml_filers = [
        get_node("hix-ee:TaxHousehold/hix-ee:PrimaryTaxFiler", xml_return),
        get_node("hix-ee:TaxHousehold/hix-ee:SpouseTaxFiler", xml_return)
      ]

      filers = xml_filers.select{|xf| xf}.map{|xf|
        TaxPerson.new(
          @people.find{|p| p.person_id == get_node("hix-core:RoleOfPersonReference", xf).attribute('ref').value}
        )
      }
      
      dependents = get_nodes("hix-ee:TaxHousehold/hix-ee:PrimaryTaxFiler/RoleOfPersonReference", xml_return).map{|node|
        @people.find{|p| p.person_id == node.attribute('ref').value}
      }

      @tax_returns << TaxReturn.new(filers, dependents)
    end

    # get physical households
    @physical_households = []
    xml_physical_households = get_nodes("/exch:AccountTransferRequest/ext:PhysicalHousehold")
    for xml_household in xml_physical_households
      person_references = get_nodes("hix-ee:HouseholdMemberReference", xml_household).map{|node| node.attribute('ref').value}

      @physical_households << Household.new(nil, person_references.map{|ref| @people.find{|p| p.person_id == ref}})
    end
  end

  def get_xml_variable(node, input, person_id)
    unless node
      raise "Input xml missing variable #{input[:name]} for person #{person_id}"
    end

    if input[:type] == :integer
      node.inner_text.to_i
    elsif input[:type] == :flag
      if input[:values].include? node.inner_text
        node.inner_text
      elsif node.inner_text == 'true'
        'Y'
      elsif node.inner_text == 'false'
        'N'
      else
        raise "Invalid value #{node.inner_text} for variable #{input[:name]} for person #{person_id}"
      end 
    elsif input[:type] == :string
      node.inner_text
    else
      raise "Variable #{input[:name]} has unimplemented type #{input[:type]}"
    end
  end

  def to_xml
    Nokogiri::XML::Builder.new(:encoding => 'UTF-8') do |xml|
      xml.send("exch:AccountTransferRequest", Hash[XML_NAMESPACES.map{|k, v| ["xmlns:#{k}", v]}]) {
        xml.send("ext:TransferHeader") {
          xml.send("ext:TransferActivity") {
            xml.send("nc:ActivityIdentification") {
              # Need Identification ID
            }
            xml.send("nc:ActivityDate") {
              xml.send("nc:DateTime", Time.now.strftime("%Y-%m-%dT%H:%M:%S"))
            }
            xml.send("ext:TransferActivityReferralQuantity", @applicants.length)
            xml.send("ext:RecipientTransferActivityCode", "MedicaidCHIP")
            xml.send("ext:RecipientTransferActivityStateCode", @state)
          }
        }
        xml.send("hix_core:Sender") {
          # Need to figure out what to put here
        }
        xml.send("hix_core:Receiver") {
          # Need to figure out what to put here
        }
        xml.send("hix-ee:InsuranceApplication") {
          xml.send("hix-core:ApplicationCreation") {
            # Need to figure out what to put here
          }
          xml.send("hix-core:ApplicationSubmission") {
            # Need to figure out what to put here
          }
          # Do we want Application Identification?
          @applicants.each do |applicant|
            xml.send("hix-ee:InsuranceApplicant", {"s:id" => applicant.applicant_id}) {
              xml.send("hix-ee:MedicaidMAGIEligibility") {
                ApplicationVariables::DETERMINATIONS.select{|det| det[:eligibility] == :MAGI}.each do |determination|
                  det_name = determination[:name]
                  xml.send("hix-ee:MedicaidMAGI#{det_name.gsub(/ +/,'')}EligibilityBasis") {
                    build_determinations(xml, det_name, applicant)
                  }
                end
                ApplicationVariables::OUTPUTS.select{|o| o[:group] == :MAGI}.each do |output|
                  xml.send(output[:xpath], applicant.outputs[output[:name]])
                end
              }
              xml.send("hix-ee:CHIPEligibility") {
                ApplicationVariables::DETERMINATIONS.select{|det| det[:eligibility] == :CHIP}.each do |determination|
                  det_name = determination[:name]
                  xml.send("hix-ee:#{det_name.gsub(/ +/,'')}EligibilityBasis") {
                    build_determinations(xml, det_name, applicant)
                  }
                end
              }
              xml.send("hix-ee:MedicaidNonMAGIEligibility") {
                det_name = "Medicaid Non-MAGI Referral"
                xml.send("hix-ee:EligibilityIndicator", applicant.outputs["Applicant #{det_name} Indicator"])
                xml.send("hix-ee:EligibilityDetermination") {
                  xml.send("nc:ActivityDate") {
                    xml.send("nc:DateTime", applicant.outputs["#{det_name} Determination Date"].strftime("%Y-%m-%d"))
                  }
                }
                xml.send("hix-ee:EligibilityReasonText", applicant.outputs["#{det_name} Ineligibility Reason"])
              }
            }
          end
        }
        if return_application?
          @people.each do |person|
            xml.send("hix-core:Person", {"s:id" => person.person_id}) {

            }
          end
          @physical_households.each do |household|
            xml.send("ext:PhysicalHousehold") {
              household.people.each do |person|
                xml.send("hix-ee:HouseholdMemberReference", {"s:ref" => person.person_id})
              end
            }
          end
        end
      }
    end
  end

  def build_determinations(xml, det_name, applicant)
    xml.send("hix-ee:EligibilityBasisStatusIndicator", applicant.outputs["Applicant #{det_name} Indicator"])
    xml.send("hix-ee:EligibilityBasisDetermination") {
      xml.send("nc:ActivityDate") {
        xml.send("nc:DateTime", applicant.outputs["#{det_name} Determination Date"].strftime("%Y-%m-%d"))
      }
    }
    xml.send("hix-ee:EligibilityBasisIneligibilityReasonText", applicant.outputs["#{det_name} Ineligibility Reason"])
  end

  def build_xpath(xml, xpath)
    xpath = xpath.gsub(/^\/+/,'')
    unless xpath.empty?
      xpath_list = xpath.split('/')
      xml.send(xpath_list.first) {
        build_path(xml, xpath_list[1..-1].join('/'))
      }
    end
  end

  def calculate_values!

  end

  def from_context!(applicant, context)
    applicant.outputs.merge!(context.output)
  end

  def to_context(applicant)
    input = applicant.applicant_attributes.merge(applicant.person_attributes).merge(applicant.outputs)
    input.merge!({
      "Applicant ID" => applicant.applicant_id,
      "Person ID" => applicant.person_id,
      "Applicant List" => @applicants,
      "Person List" => @people,
      "Applicant Relationships" => applicant.relationships || [],
      "Physical Household" => @physical_households.find{|hh| hh.people.any?{|p| p.person_id == applicant.person_id}},
      "Tax Returns" => @tax_returns || []
    })
    config = @config
    RuleContext.new(config, input, @determination_date)
  end

  def to_hash()
    {
      :config => @config,
      :applicants => @applicants.map{|a|
        {
          :id => a.applicant_id,
          :person_id => a.person_id,
          :attributes => a.applicant_attributes.merge(a.person_attributes),
          :relationships => (a.relationships || []).map{|r|
            {
              :other_id => r.person.person_id,
              :relationship => r.relationship,
              :attributes => r.relationship_attributes
            }
          },
          :outputs => a.outputs
        }
      },
      :households => @physical_households.map{|ph|
        ph.people.map{|p|
          {
            :person_id => p.person_id
          }
        }
      },
      :tax_returns => @tax_returns.map{|tr|
        {
          :filers => tr.filers.map{|f|
            {
              :person_id => f.person.person_id
            }
          },
          :dependents => tr.dependents.map{|d|
            {
              :person_id => d.person_id
            }
          }
        }
      }
    }
  end

  def process_rules!
    magi_part_1 = [
      Medicaid::Eligibility::Category::ParentCaretakerRelative,
      Medicaidchip::Eligibility::Category::Pregnant,
      Medicaidchip::Eligibility::Category::Child,
      Medicaid::Eligibility::Category::Medicaid::AdultGroup,
      Medicaid::Eligibility::Category::OptionalTargetedLowIncomeChildren,
      Chip::Eligibility::Category::TargetedLowIncomeChildren,
      Medicaid::Eligibility::ReferralType
    ].map{|ruleset_class| ruleset_class.new()}

    for applicant in @applicants
      for ruleset in magi_part_1
        context = to_context(applicant)
        ruleset.run(context)
        from_context!(applicant, context)
      end
    end

    income_ruleset = Medicaidchip::Eligibility::Income.new()
  end
end