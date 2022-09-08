###################################################################################################
# Translation logic: Elements flat metadata to eSchol API JSON

require 'date'
require 'sequel'

require_relative './sanitize.rb'

###################################################################################################
# Connect to the eschol5 database server
DB = Sequel.connect({
  "adapter"  => "mysql2",
  "host"     => ENV["ESCHOL_DB_HOST"] || raise("missing env ESCHOL_DB_HOST"),
  "port"     => ENV["ESCHOL_DB_PORT"] || raise("missing env ESCHOL_DB_PORT").to_i,
  "database" => ENV["ESCHOL_DB_DATABASE"] || raise("missing env ESCHOL_DB_DATABASE").to_i,
  "username" => ENV["ESCHOL_DB_USERNAME"] || raise("missing env ESCHOL_DB_USERNAME"),
  "password" => ENV["ESCHOL_DB_PASSWORD"] || raise("missing env ESCHOL_DB_HOST") })

###################################################################################################
# Elements group IDs, used to determine into which campus postprint bucket to deposit.
$groupToCampus = { 684 => 'lbnl',
                   430 => 'ucb',
                   431 => 'ucd',
                   3   => 'uci',
                   4   => 'ucla',
                   400 => 'ucm',
                   432 => 'ucr',
                   282 => 'ucsd',
                   2   => 'ucsf',
                   286 => 'ucsb',
                   280 => 'ucsc',
                   1164 => 'ucop' }

$groupToRGPO = { 784 => 'CBCRP',
                 785 => 'CHRP',
                 787 => 'TRDRP',
                 786 => 'UCRI' }

###################################################################################################
$repecIDs = {}
MAX_REPEC_IDS = 10

###################################################################################################
def guessMimeType(filePath)
  Rack::Mime.mime_type(File.extname(filePath))
end

###################################################################################################
def isPDF(filename)
  return guessMimeType(filename) == "application/pdf"
end

###################################################################################################
def isWordDoc(filename)
  return guessMimeType(filename) =~ %r{application/(msword|rtf|vnd.openxmlformats-officedocument.wordprocessingml.document)}
end

###################################################################################################
def convertPubType(pubTypeStr)
  case pubTypeStr
    when %r{^(journal-article|conference|conference-proceeding|internet-publication|scholarly-edition|report|preprint)$}; 'ARTICLE'
    when %r{^(dataset|poster|media|presentation|other)$}; 'NON_TEXTUAL'
    when "book"; 'MONOGRAPH'
    when "chapter"; 'CHAPTER'
    else raise "Can't recognize pubType #{pubTypeStr.inspect}" # Happens when Elements changes or adds types
  end
end

###################################################################################################
def convertKeywords(kws)
  # Transform "1505 Marketing (for)" to just "Marketing"
  kws.map { |kw|
    # Remove scheme at end, and remove initial series of digits
    kw.sub(%r{ \([^)]+\)$}, '').sub(%r{^\d+ }, '')
  }.uniq
end

###################################################################################################
def parseMetadataEntries(feed)
  metaHash = {}
  feed.xpath(".//metadataentry").each { |ent|
    key = ent.text_at('key')
    value = ent.text_at('value')
    if key == 'keywords'
      metaHash[key] ||= []
      metaHash[key] << value
    elsif key == 'proceedings'
      metaHash.key?(key) or metaHash[key] = value   # Take first one only (for now at least)
    else
      metaHash.key?(key) and raise("double key #{key}")
      metaHash[key] = value
    end
  }
  return metaHash
end

###################################################################################################
def convertPubDate(pubDate)
  case pubDate
    when /^\d\d\d\d-[01]\d-[0123]\d$/; pubDate
    when /^\d\d\d\d-[01]\d$/;          "#{pubDate}-01"
    when /^\d\d\d\d$/;                 "#{pubDate}-01-01"
    when nil;                          Date.today.iso8601
    else;                              raise("Unrecognized date.issued format: #{pubDate.inspect}")
  end
end

###################################################################################################
def convertFileVersion(fileVersion)
  case fileVersion
    # Pre-v6.8 terms
    when /(Author final|Submitted) version/; 'AUTHOR_VERSION'
    when "Published version"; 'PUBLISHER_VERSION'
    # Post-v6.8 terms
    when /(Publisher's|Published) version/; 'PUBLISHER_VERSION'
    when /(Accepted|Submitted) version*/,
         "Author's accepted manuscript";'AUTHOR_VERSION'
    else raise "Unrecognized file version '#{fileVersion}'"
  end
end

###################################################################################################
def assignSeries(data, completionDate, metaHash)
  # See https://docs.google.com/document/d/1U_DG-_iPOnS_Rp8Wu6COIgcNcicDtonOM9aZCCsJoQI/edit
  # for a prose description of our method here.

  # In general we want to retain existing units. Grab a list of those first.
  # We use a Hash, which preserves order of insertion (vs. Set which seems to but isn't guaranteed)
  series = {}
  (data[:units] || []).each { |unit|
    # Filter out old RGPO errors
    if !(unit =~ /^(cbcrp_rw|chrp_rw|trdrp_rw|ucri_rw)$/)
      series[unit] = true
    end
  }

  # Make a list of campus associations using the Elements groups associated with the incoming item.
  # Format of the groups string is e.g. "435:UC Berkeley (senate faculty)|430:UC Berkeley|..."
  groupStr = metaHash.delete("groups") or raise("missing 'groups' in deposit data")
  groups = Hash[groupStr.split("|").map { |pair|
    pair =~ /^(\d+):(.*)$/ or raise("can't parse group pair #{pair.inspect}")
    [$1.to_i, $2]
  }]
  rgpoUnits = Set.new
  campusSeries = groups.map { |groupID, groupName|

    # Regular campus
    if $groupToCampus[groupID]
      (groupID == 684) ? "lbnl_rw" : "#{$groupToCampus[groupID]}_postprints"

    # RGPO special logic
    elsif $groupToRGPO[groupID]
      # If completed on or after 2017-01-08, check funding
      if (completionDate >= Date.new(2017,1,8)) && metaHash['funder-name'] &&
         (metaHash['funder-name'].include?($groupToRGPO[groupID]))
        rgpoUnit = "#{$groupToRGPO[groupID].downcase}_rw"
      else
        rgpoUnit = "rgpo_rw"
      end
      rgpoUnits << rgpoUnit
      rgpoUnit
    else
      nil
    end
  }.compact

  # Add campus series in sorted order (special: always sort lbnl first, and rgpo last)
  rgpoPat = Regexp.compile("^(#{rgpoUnits.to_a.join("|")})$")
  campusSeries.sort { |a, b|
    a.sub('lbnl','0').sub(rgpoPat,'zz') <=> b.sub('lbnl','0').sub(rgpoPat,'zz')
  }.each { |s|
    series.key?(s) or series[s] = true
  }

  # Figure out which departments correspond to which Elements groups.
  # Note: this query is so fast (< 0.01 sec) that it's not worth caching.
  # Note: departments always come after campus
  depts = Hash[DB.fetch("""SELECT id unit_id, attrs->>'$.elements_id' elements_id FROM units
                           WHERE attrs->>'$.elements_id' is not null""").map { |row|
    [row[:elements_id].to_i, row[:unit_id]]
  }]

  # Add any matching departments for this publication
  deptSeries = groups.map { |groupID, groupName| depts[groupID] }.compact

  # Add department series in sorted order (and avoid dupes)
  deptSeries.sort.each { |s| series.key?(s) or series[s] = true }

  # All done.
  return data[:units] = series.keys
end

###################################################################################################
def getCompletionDate(oldData, metaHash)
  # If there's a recorded escholPublicationDate, use that.
  oldData[:published] and return oldData[:published]

  # Otherwise, use the deposit date from the feed
  feedCompleted = metaHash['deposit-date'] or raise("can't find deposit-date")
  return Date.parse(feedCompleted, "%d-%m-%Y")
end

###################################################################################################
def convertFunding(metaHash)
  funderNames = metaHash.delete("funder-name").split("|")
  funderIds   = metaHash.delete("funder-reference")&.split("|")
  if funderIds.nil?
     return nil
  end 
  return funderNames.map.with_index { |name, idx| { reference: funderIds[idx], name: name } }.select{|r| r[:reference] != nil and !r[:reference].empty?}
end

###################################################################################################


def convertOALocation(ark, metaHash, data)
  loc = metaHash.delete("oa-location-url")
  if loc =~ %r{search.library.(berkeley|ucla|ucr|ucdavis|ucsb|ucsf).edu} or loc =~ %r{primo.exlibrisgroup.com} or loc =~ %r{search-library.ucsd.edu}
    userErrorHalt(ark, "The link you provided may not be accessible to readers outside of UC. \n" +
    "Please provide a link to an open access version of this article.")
  end
  if loc =~ %r{escholarship.org}
    userErrorHalt(ark, "The link you provided is to an existing eScholarship item. \n" +
                       "There is no need to re-deposit this item.")
  end
  data[:externalLinks] ||= []
  data[:externalLinks] << loc
end

###################################################################################################
def assignEmbargo(metaHash)
  reqPeriod = metaHash.delete("requested-embargo.display-name")
  if metaHash.delete("confidential") == "true"
    return '2999-12-31' # this should be long enough to count as indefinite
  else
    case reqPeriod
      when nil, /Not known|No embargo|Unknown/
        return nil
      when /Indefinite/
        return '2999-12-31' # this should be long enough to count as indefinite
      when /^(\d+) month(s?)/
        return (Date.today >> ($1.to_i)).iso8601
      else
        raise "Unknown embargo period format: '#{reqPeriod}'"
    end
  end
end

###################################################################################################
def convertPubStatus(elementsStatus)
  case elementsStatus
    when /None|Unpublished|Submitted/i
      'INTERNAL_PUB'
    when /Published/i
      'EXTERNAL_PUB'
    else
      'EXTERNAL_ACCEPT'
  end
end

###################################################################################################
# Lookup, and cache, a RePEc ID for the given pub. We cache to speed the case of checking and
# immediately updating the metadata.
def lookupRepecID(elemPubID)
  if !$repecIDs.key?(elemPubID)
    # The only way we know of to get the RePEc ID is to ask the Elements API.
    apiHost = ENV['ELEMENTS_API_URL'] || raise("missing env ELEMENTS_API_URL")
    resp = HTTParty.get("#{apiHost}/publications/#{elemPubID}", :basic_auth =>
      { :username => ENV['ELEMENTS_API_USERNAME'] || raise("missing env ELEMENTS_API_USERNAME"),
        :password => ENV['ELEMENTS_API_PASSWORD'] || raise("missing env ELEMENTS_API_PASSWORD") })
    resp.code == 404 and return nil  # sometimes Elements does meta update on non-existent pub, e.g 2577213. Weird.
    resp.code == 410 and return nil  # sometimes Elements does meta update on deleted pub, e.g 2564054. Weird.
    resp.code == 200 or raise("Updated message : Got error from Elements API #{apiHost} for pub #{elemPubID}: #{resp}")

    data = Nokogiri::XML(resp.body).remove_namespaces!
    repecID = data.xpath("//record[@source-name='repec']").map{ |r| r['id-at-source'] }.compact[0]

    $repecIDs.size >= MAX_USER_ERRORS and $repecIDs.shift
    $repecIDs[elemPubID] = repecID
  end
  return $repecIDs[elemPubID]
end

###################################################################################################
# Take feed XML from Elements and make an eschol JSON record out of it. Note that if you pass
# existing eschol data in, it will be retained if Elements doesn't override it.
def elementsToJSON(oldData, elemPubID, submitterEmail, metaHash, ark, feedFile)

  # eSchol ARK identifier (provisional ID minted previously for new items)
  data = oldData ? oldData.clone : {}
  data[:id] = ark

  # Identify the source system
  data[:sourceName] = 'elements'
  data[:sourceID] = elemPubID
  data[:sourceFeedLink] = "#{$submitServer}/bitstreamTmp/#{feedFile}"

  # Object type, flags, status, etc.
  elementsPubType = metaHash.delete('object.type') || raise("missing object.type")
  data[:type] = convertPubType(elementsPubType)
  data[:isPeerReviewed] = true  # assume all Elements items are peer reviewed
  if (elementsPubType == 'preprint')  
    data[:isPeerReviewed] = false  # assume preprints are not peer reviewed
  end  
  data[:pubRelation] = convertPubStatus(metaHash.delete('publication-status'))
  data[:embargoExpires] = assignEmbargo(metaHash)

  # Author and editor metadata.
  metaHash['authors'] && data[:authors] = transformPeople(metaHash.delete('authors'), nil)
  if metaHash['editors'] || metaHash['advisors']
    contribs = []
    metaHash['editors'] and contribs += (transformPeople(metaHash.delete('editors'), 'EDITOR') || [])
    metaHash['advisors'] and contribs += (transformPeople(metaHash.delete('advisors'), 'ADVISOR') || [])
    !contribs.empty? and data[:contributors] = contribs
  end

  # Other top-level fields
  metaHash.key?('title') and data[:title] = sanitizeHTML(metaHash.delete('title')).gsub(/\s+/, ' ').strip
  metaHash.key?('abstract') and data[:abstract] = sanitizeHTML(metaHash.delete('abstract'))
  data[:localIDs] = []
  metaHash.key?('doi') and data[:localIDs] << { id: metaHash.delete('doi'), scheme: 'DOI' }
  data[:localIDs] << {id: elemPubID, scheme: 'OA_PUB_ID'}
  metaHash.key?('fpage') and data[:fpage] = metaHash.delete('fpage')
  metaHash.key?('lpage') and data[:lpage] = metaHash.delete('lpage')
  metaHash.key?('keywords') and data[:keywords] = convertKeywords(metaHash.delete('keywords'))
  if metaHash.key?('requested-reuse-licence.short-name')
    ccCode = metaHash.delete('requested-reuse-licence.short-name')
    data[:rights] = "https://creativecommons.org/licenses/#{ccCode.sub("CC ", "").downcase}/4.0/"
  end
  metaHash.key?('funder-name') and data[:grants] = convertFunding(metaHash)

  # Context
  assignSeries(data, getCompletionDate(data, metaHash), metaHash)
  lookupRepecID(elemPubID) and data[:localIDs] << { scheme: 'OTHER_ID', subScheme: 'repec', id: lookupRepecID(elemPubID) }
  metaHash.key?("report-number") and data[:localIDs] << {
    scheme: 'OTHER_ID', subScheme: 'report', id: metaHash.delete('report-number')
  }
  metaHash.key?("issn") and data[:issn] = metaHash.delete("issn")
  metaHash.key?("isbn-13") and data[:isbn] = metaHash.delete("isbn-13") # for books and chapters
  metaHash.key?("journal") and data[:journal] = metaHash.delete("journal")
  metaHash.key?("proceedings") and data[:proceedings] = metaHash.delete("proceedings")
  metaHash.key?("volume") and data[:volume] = metaHash.delete("volume")
  metaHash.key?("issue") and data[:issue] = metaHash.delete("issue")
  metaHash.key?("parent-title") and data[:bookTitle] = metaHash.delete("parent-title")  # for chapters 
  metaHash.key?("oa-location-url") and convertOALocation(ark, metaHash, data)
  data[:ucpmsPubType] = elementsPubType

  # History
  data[:published] = convertPubDate(metaHash.delete('publication-date'))
  data[:submitterEmail] = submitterEmail

  # Custom Citation Field
  metaHash.key?("custom-citation") and data[:customCitation] = metaHash.delete("custom-citation")

  # All done.
  return data
end

###################################################################################################
def transformPeople(pieces, role)

  # Now build the resulting UCI author records.
  people = []
  person = nil
  pieces.split(/\|\| *\n/).each { |line|
    line =~ %r{\[([-a-z]+)\] ([^|]*)} or raise("can't parse people line #{line.inspect}")
    field, value = $1, $2
    case field
      when 'start-person'
        person = {}
      when 'lastname'
        person[:nameParts] ||= {}
        person[:nameParts][:lname] = value
      when 'firstnames', 'initials'
        # Prefer longer of firstname or initials
        if !person[:nameParts][:fname] || person[:nameParts][:fname].size < value.size
          person[:nameParts][:fname] = value
        end
      # Fix for filtering non-UC author emails
      # when 'email-address', 'resolved-user-email'
      when 'resolved-user-email'
        person[:email] = value
      when 'resolved-user-orcid'
        person[:orcid] = value
      when 'identifier'
        #puts "TODO: Handle identifiers like #{value.inspect}"
        # puts("Identifier found. #{value}")
        if value.include? "(orcid)"
          orcidid = value.split[0]
          # puts("orcid found: #{orcidid}")
          person[:orcid] = value.split[0]
        end
      when 'end-person'
        if !person.empty?
          role and person[:role] = role
          people << person
        end
        person = nil
      when 'address'
        # e.g. "University of California, Berkeley\nBerkeley\nUnited States"
        # do nothing with it for now
      else
        raise("Unexpected person field #{field.inspect}")
    end
  }

  return people.empty? ? nil : people
end
