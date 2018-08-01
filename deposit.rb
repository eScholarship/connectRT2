
###################################################################################################
# External code modules
require 'cgi'
require 'fileutils'
require 'open3'
require 'yaml'
require 'open-uri'
require 'open4'
require 'netrc'
require 'sqlite3'
require 'equivalent-xml'
require 'net/smtp'
require 'unindent'
require "#{$espylib}/ark.rb"
require "#{$espylib}/subprocess.rb"
require "#{$espylib}/xmlutil.rb"
require "#{$espylib}/stringutil.rb"
require "#{$subiDir}/lib/rawItem.rb"
require "#{$subiDir}/lib/subiGuts.rb"

###################################################################################################
# Use absolute paths to executables so we don't depend on PATH env (monit doesn't give us a good PATH)
$java = "/usr/pkg/java/oracle-8/bin/java"
$libreOffice = "/usr/pkg/bin/soffice"

# Fix up LD_LIBRARY_PATH so that pdfPageSizes can run successfully
ENV['LD_LIBRARY_PATH'] = (ENV['LD_LIBRARY_PATH'] || '') + ":/usr/pkg/lib"

$scanMode = false

###################################################################################################
# Exception used to throw out to the outer level noting that a fault was already recorded.
class FaultRecorded < StandardError
end

# We'll need to look things up in the arks database, so open it now.
$arkDb = SQLite3::Database.new("#{$controlDir}/db/arks.db")
$arkDb.busy_timeout = 30000

###################################################################################################
# Strings to pick out from <organisational-details>/</group> to determine campus.
$campusNames = { 'Lawrence Berkeley Lab' => 'lbnl',
                 'UC Berkeley'           => 'ucb',
                 'UC Davis'              => 'ucd',
                 'UC Irvine'             => 'uci',
                 'UC Los Angeles'        => 'ucla',
                 'UC Merced'             => 'ucm',
                 'UC Riverside'          => 'ucr',
                 'UC San Diego'          => 'ucsd',
                 'UC San Francisco'      => 'ucsf',
                 'UC Santa Barbara'      => 'ucsb',
                 'UC Santa Cruz'         => 'ucsc' }

###################################################################################################
# Make a filename from the outside safe for use as a file on our system.
def sanitizeFilename(fn)
  fn.gsub(/[^-A-Za-z0-9_.]/, "_")
end

###################################################################################################
# Convert an elements publication ID to an ARK on our system. This will create
# a new ark if we haven't seen the publication before.
def mintArk(pubID)
  ark = `#{$controlDir}/tools/mintArk.py elements #{pubID}`.strip()
  return (ark =~ %r<^ark:/?13030/\w{10}$>) ? ark : raise("bad result '#{ark}' from mintArk")
end

###################################################################################################
def isMetaChanged(ark, feedData)

  # Read the old metadata
  metaPath = arkToFile(ark, "next/meta/base.meta.xml")
  File.file?(metaPath) or metaPath = arkToFile(ark, "meta/base.meta.xml")
  uci = File.file?(metaPath) ? fileToXML(metaPath) :
        Nokogiri::XML("<uci:record xmlns:uci='http://www.cdlib.org/ucingest'/>")

  # Keep a backup of the old data, then integrate the feed into new metadata
  uciOld = uci.dup
  begin
    uciFromFeed(uci.root, feedData, :ark => ark)
  rescue Exception => e
    puts "Warning: unable to parse feed: #{e}"
    puts e.backtrace
    return false
  end

  # See if there's any significant change
  firstDiff = nil
  equiv = EquivalentXml.equivalent?(uciOld, uci) { |n1, n2, result|
    if result || n1.path =~ /@dateStamp$/
      true
    else
      firstDiff ||= firstDiff = n1.path
      false
    end
  }

  # For diagnostic purposes, if there's a diff say where (in a compact way)
  firstDiff and print "(#{firstDiff.sub('/uci:record/','').sub('/text()','')}) "

  # Meta is changed if it's not equivalent
  return !equiv
end

###################################################################################################
def updateMetadata(ark, fileVersion=nil)

  # Transform the metadata feed to a UCI metadata file.
  feedPath = arkToFile(ark, "next/meta/base.feed.xml")
  feed = fileToXML(feedPath).remove_namespaces!

  metaPathOld = arkToFile(ark, "next/meta/base.meta.xml.old")
  metaPathCur = arkToFile(ark, "next/meta/base.meta.xml")
  metaPathTmp = arkToFile(ark, "next/meta/base.meta.xml.new")

  uci = File.file?(metaPathCur) ? fileToXML(metaPathCur) :
        Nokogiri::XML("<uci:record xmlns:uci='http://www.cdlib.org/ucingest'/>")

  uciFromFeed(uci.root, feed.root, :ark => ark, :fileVersion => fileVersion)
  File.open(metaPathTmp, 'w') { |io| uci.write_xml_to(io, indent:3) }

  # For info, run Jing validation on the result, but don't check the return code.
  cmd = [$java, '-jar', "#{$erepDir}/control/xsl/jing.jar",
         '-c', "#{$erepDir}/schema/uci_schema.rnc",
         metaPathTmp]
  puts "Running jing: '#{cmd.join(" ")}'"
  system(*cmd)

  # Replace the old metadata with the new
  File.rename(metaPathCur, metaPathOld) if File.file? metaPathCur
  File.rename(metaPathTmp, metaPathCur)
  return true

end

###################################################################################################
def isPDF(filename)
  return SubiGuts.guessMimeType(filename) == "application/pdf"
end

###################################################################################################
def isWordDoc(filename)
  return SubiGuts.guessMimeType(filename) =~
    %r{application/(msword|rtf|vnd.openxmlformats-officedocument.wordprocessingml.document)}
end

###################################################################################################
# If the user uploads a Word doc, convert it to a PDF. If it's already a PDF, just copy it. In
# either case, return the path to the new file. If it's not Word or PDF, return nil.
def convertToPDF(ark, uploadedPath)
  outPath = arkToFile(ark, "next/content/base.pdf")

  # If already a PDF, just return it.
  if isPDF(uploadedPath)
    FileUtils.copy(uploadedPath, outPath)
    return outPath
  end

  # If it's a Word doc, convert with LibreOffice
  if isWordDoc(uploadedPath)
    tmpFile = uploadedPath.sub(File.extname(uploadedPath), '.pdf')
    File.delete(tmpFile) if File.exist? tmpFile
    checkCall([$libreOffice, '--headless', '--convert-to', 'pdf', '-outdir', arkToFile(ark, 'next/content'), uploadedPath])
    File.exist? tmpFile or raise "LibreOffice did not produce expected file '#{tmpFile}'"
    File.rename(tmpFile, outPath)
    return outPath
  end

  # None of the above. We can't convert it.
  return nil

end

###################################################################################################
# If the user uploads a Word doc, convert it to a PDF. If it's already a PDF, just copy it. In
# either case, return the path to the new file. If it's not Word or PDF, return nil.
def generatePreviewData(ark, pdfPath)
  begin
    sizesPath = arkToFile(ark, "next/rip/base.pageSizes.xml", true)
    puts "Sizing: #{pdfPath} -> #{sizesPath}"
    File.open(sizesPath, 'wb') { |io|
      Open4.spawn(["/usr/pkg/bin/pdfPageSizes", pdfPath],
                  :timeout=>30, # limit to 30 secs to avoid user thinking we hung
                  :stdout=>io)
    }
  rescue
    # Print a warning to the log but do nothing else. It'll get sized eventually when the item
    # is published.
    puts "Warning: pdfPageSizes timed out on #{pdfPath}"
  end

  begin
    coordPath = arkToFile(ark, "next/rip/base.textCoords.xml", true)
    puts "Ripping: #{pdfPath} -> #{coordPath}"
    Open4.spawn(["/usr/pkg/bin/pdfToTextCoords", pdfPath, coordPath],
                :timeout=>30) # limit to 30 secs to avoid user thinking we hung
  rescue
    # Print a warning to the log but do nothing else. It'll get sized eventually when the item
    # is published.
    puts "Warning: pdfToTextCoords timed out on #{pdfPath}"
  end
end

###################################################################################################
def isModifiableItem(ark)

  # We support modifying items that:
  # 1. aren't imported, or
  # 2. are campus postprints

  # If no existing metadata, it's definitely not imported, and is thus modifiable
  ark or return true
  metaPath = arkToBestFile(ark, "meta/base.meta.xml")
  metaPath or return true
  File.exists?(metaPath) or return true

  # If there's a source element, oa_harvester indicates stuff from Elements. We consider it to be
  # always ok to modify Elements stuff using Elements.
  meta = fileToXML(metaPath).root
  source = meta.text_at("source")
  return true if source == 'oa_harvester'

  # Things that didn't come from Subi or bepress (such as ojs, springer) can't be considered
  # campus postprints. So they can't be modified.
  return false unless source =~ /^(subi|repo)$/

  # Okay, grab the entity and check if it's a campus postprint.
  entity = meta.text_at("context/entity/@id")
  return true if entity =~ /^(ucb|ucd|uci|ucla|ucm|ucr|ucsd|ucsf|ucsb|ucsc|ucop)_postprints$/

  # Subi items other than campus postprints cannot be modified
  return false
end

###################################################################################################
# Record in our database that the given pub is equivalent to the given pre-existing eScholarship
# item. This is so we can later respond properly when Elements asks about it. Nothing is actually
# going to happen on the eSchol front-end.
def makeEquiv(pubID, ark)

  # Record it
  $oapDb.execute("INSERT INTO eschol_equiv VALUES (?,?)", [pubID, ark])

  # Invent a proper POST response
  content_type "application/atom+xml;type=feed"
  url = "#{$server}/license/#{getShortArk(ark)}/meta/license/no_revoke_synthetic_license-#{pubID}"
  responseText = respondToDeposit(nil, url, true)
  [201, [responseText]]

end

###################################################################################################
def depositFile(ark, filename, fileVersion, inStream)

  if !(isModifiableItem(ark))
    halt 401, "Cannot use Elements to change a non-campus-postprint imported from eSchol"
  end

  # Get rid of any weird chars in the filename
  filename = sanitizeFilename(filename)

  # Create a next directory if the item has been published
  editItem(ark)

  # If user tries to upload something we can't use as a content doc, always treat it as supplemental.
  forcedSupp = false
  if fileVersion != 'Supporting information' && !(isPDF(filename) || isWordDoc(filename))
    fileVersion = 'Supporting information'
    forcedSupp = true
  end

  # Save the file data in the appropriate place.
  if fileVersion == 'Supporting information'
    uploadedPath = arkToFile(ark, "next/content/supp/#{filename}", true)
    updType = "supp"
  else
    uploadedPath = arkToFile(ark, "next/content/#{filename}", true)
    updType = "content"
  end
  File.open(uploadedPath, "wb") { |io| FileUtils.copy_stream(inStream, io) }

  # If the file looks like a PDF, make sure the Unix 'file' command agrees.
  uploadedMimeType = SubiGuts.guessMimeType(uploadedPath)
  if uploadedMimeType =~ /pdf/
    if !(checkOutput(['/usr/bin/file', '--brief', uploadedPath]) =~ /PDF/i)
      raise("Non-PDF uploaded as PDF")
    end
  end

  # Insert UCI metadata for the uploaded file
  editXML(arkToFile(ark, "next/meta/base.meta.xml")) do |meta|
    partialUploadedPath = uploadedPath.sub(%r{.*/content/}, 'content/')
    contentEl = meta.find! 'content', before:'context'

    # Content file processing
    if updType == 'content'
      pdfPath = convertToPDF(ark, uploadedPath)  # TODO: If this fails, email eschol staff

      pdfPath and generatePreviewData(ark, pdfPath)
      partialPdfPath = pdfPath.sub(%r{.*/content/}, 'content/')
      # Remove existing file and its element - we will replace them
      contentEl.xpath('file/native/file[@path]') do |nfEl|
        if nfEl[:path] != partialUploadedPath
          nfPath = arkToFile(ark, nfEl[:path])
          puts "Deleting old native file '#{nfPath}'"
          File.delete nfPath if File.exist? nfPath
        end
      end
      contentEl.xpath('file').remove
      # Make a new 'native' file element
      contentEl.build { |xml|
        xml.file(path:partialPdfPath) {
          xml.mimeType SubiGuts.guessMimeType(pdfPath)
          xml.fileSize SubiGuts.getHumanSize(pdfPath)
          xml.native(path:partialUploadedPath) {
            xml.mimeType uploadedMimeType
            xml.fileSize SubiGuts.getHumanSize(uploadedPath)
            xml.originalName File.basename(uploadedPath)
          }
        }
      }
    elsif updType == 'supp'
      # Supplemental file processing (for now we also treat non-PDF content files as supp)
      suppEl = contentEl.find! 'supplemental'
      # Remove existing file element of the same path (if any) - we will replace it
      suppEl.xpath("file[@path='#{partialUploadedPath}']").remove
      # Make a new file element
      suppEl.build { |xml|
        xml.file(path:partialUploadedPath) {
          xml.mimeType uploadedMimeType
          xml.fileSize SubiGuts.getHumanSize(uploadedPath)
        }
      }
    end
  end

  # If we had to force a content file into supp, note it as an item fault.
  if forcedSupp
    recordFault(ark, false, 'no_document',
                "User '#{who}' uploaded non-doc file '#{filename}' as document for Elements pub #{pubID} (#{ark}). " +
                "Treated as a supp file. We need to review this item.")
  end
end

###################################################################################################
# We receive this post when the user uploads a file to Elements. It may or may
# not be the first time we see this publication.
# OLD OLD OLD
post '/binary' do
  puts "Got binary, params is:"
  pp(params)

  # Log all exceptions
  ark = nil
  begin

    # Grab the raw data from the file streams
    rawFeedData = params["atom"][:tempfile].read
    rawFileData = params["binary"][:tempfile].read

    # Parse the metadata and find the publication ID.
    # We remove namespaces below because it just makes everything easier.
    feedMeta = Nokogiri::XML(rawFeedData).remove_namespaces!
    pubID = feedMeta.xpath("//id").select{|el|el.text =~ /^\d+$/}[0].text

    # Find who is doing this, if possible
    who = feedMeta.at_xpath("//actors/user[@type='impersonator']/email-address")
    who or who = feedMeta.at_xpath("//actors/user[@type='owner']/email-address")
    who = who.text.strip if who

    # Parse the crazy filename encoding, and figure out if this is a license grant.
    kind, filename = getCrazyFilename(request)
    isLicense = (kind =~ /licen[sc]e/)

    # If user is granting a license to a URL-only deposit, and that URL is an eScholarship item,
    # don't create a new item in eschol; instead just record it in a special database table and
    # returning immediately.
    if isLicense
      $oapDb.execute("DELETE FROM eschol_equiv WHERE pub_id = ?", pubID)  # replace old equiv record
      feedMeta.at(".//field[@name='p-oa-location']").try { |e|
        if e.text =~ %r{escholarship.org/uc/item/(\w+)}
          ark = "ark:/13030/qt#{$1}"
          File.exists?(arkToFile(ark, "meta/base.meta.xml")) or
            raise "Trying to associate invalid eScholarship URL #{e.text} to pub #{pubID}"
          return makeEquiv(pubID, ark)
        end
      }
    else
      equivArk = $oapDb.get_first_value("SELECT eschol_ark FROM eschol_equiv WHERE pub_id = ?", pubID)
      if equivArk
        # We're throwing an exception here because we really didn't want to write the code for what seems
        # like a very rare case. And in fact that's justified, because so far it has never happened.
        recordFault(equivArk, false, 'no_replace',
            "User '#{who}' tried to replace eschol OA URL #{equivArk} with a file on Elements pub #{pubID}. " +
            "We don't support this.")
        raise FaultRecorded.new
      end
    end

    # Find existing ark for this publication, or mint a new one.
    ark = (arkForPub(pubID) or mintArk(pubID))
    puts "\n\nProcessing repository post for Elements pub #{pubID.inspect} <==> local #{ark.inspect}.\n"
    # Seems as if we shouldn't change metadata for items uploaded by campus contributors to a managed series, since
    # probably that manager wouldn't appreciate it.

    feedType = feedMeta.root["type"]

    if !(isModifiableItem(ark))
      raise "Cannot use Elements to change a non-campus-postprint imported from eSchol"
    end

    # Note if merges happen, but finish the request so the user isn't confused.
    detectMergeProblem(pubID, ark, feedMeta, who)

    # Create a next directory if the item has been published
    editItem(ark, who, pubID)

    # Save the ATOM feed data
    File.open(arkToFile(ark, "next/meta/base.feed.xml", true), "w") { |io| feedMeta.write_xml_to io }

    # Find the file version in the feed.
    fileVersion = feedMeta.at_xpath("//file-upload/file-version")
    fileVersion = fileVersion.text.strip if fileVersion
    # Deal with inconsistency between servers
    if fileVersion == 'Supplemental file'
      fileVersion = 'Supporting information'
    end

    # If user tries to upload something we can't use as a content doc, always treat it as supplemental.
    forcedSupp = false
    if !isLicense && fileVersion != 'Supporting information' && !(isPDF(filename) || isWordDoc(filename))
      fileVersion = 'Supporting information'
      forcedSupp = true
    end

    # Save the file data in the appropriate place.
    shortArk = getShortArk(ark)
    if isLicense
      uploadedPath = arkToFile(ark, "next/meta/license/#{filename}", true)
      url = "#{$server}/license/#{shortArk}/#{filename}"
      updType = "license"
    elsif fileVersion == 'Supporting information'
      uploadedPath = arkToFile(ark, "next/content/supp/#{filename}", true)
      url = "#{$server}/supp/#{shortArk}/#{filename}"
      updType = "supp"
    else
      uploadedPath = arkToFile(ark, "next/content/#{filename}", true)
      url = "#{$server}/content/#{shortArk}/#{filename}"
      updType = "content"
    end
    File.open(uploadedPath, "w") { |io| io.write(rawFileData) }

    # Form the response before we move anything further.
    # Finish up by making an appropriate response.
    content_type "application/atom+xml;type=feed"
    responseText = respondToDeposit(uploadedPath, url, updType=='license')

    # If the file looks like a PDF, make sure the Unix 'file' command agrees.
    uploadedMimeType = SubiGuts.guessMimeType(uploadedPath)
    if uploadedMimeType =~ /pdf/
      if !(checkOutput(['/usr/bin/file', '--brief', uploadedPath]) =~ /PDF/i)
        raise("Non-PDF uploaded as PDF")
      end
    end

    # Update metadata from the feed
    updateMetadata(ark, fileVersion)

    # Insert UCI metadata for the uploaded file
    editXML(arkToFile(ark, "next/meta/base.meta.xml")) do |meta|
      partialUploadedPath = uploadedPath.sub(%r{.*/content/}, 'content/')
      contentEl = meta.find! 'content', before:'context'

      # Content file processing
      if updType == 'content'
        pdfPath = convertToPDF(ark, uploadedPath)  # TODO: If this fails, email eschol staff

        pdfPath and generatePreviewData(ark, pdfPath)
        partialPdfPath = pdfPath.sub(%r{.*/content/}, 'content/')
        # Remove existing file and its element - we will replace them
        contentEl.xpath('file/native/file[@path]') do |nfEl|
          if nfEl[:path] != partialUploadedPath
            nfPath = arkToFile(ark, nfEl[:path])
            puts "Deleting old native file '#{nfPath}'"
            File.delete nfPath if File.exist? nfPath
          end
        end
        contentEl.xpath('file').remove
        # Make a new 'native' file element
        contentEl.build { |xml|
          xml.file(path:partialPdfPath) {
            xml.mimeType SubiGuts.guessMimeType(pdfPath)
            xml.fileSize SubiGuts.getHumanSize(pdfPath)
            xml.native(path:partialUploadedPath) {
              xml.mimeType uploadedMimeType
              xml.fileSize SubiGuts.getHumanSize(uploadedPath)
              xml.originalName File.basename(uploadedPath)
            }
          }
        }
      elsif updType == 'supp'
        # Supplemental file processing (for now we also treat non-PDF content files as supp)
        suppEl = contentEl.find! 'supplemental'
        # Remove existing file element of the same path (if any) - we will replace it
        suppEl.xpath("file[@path='#{partialUploadedPath}']").remove
        # Make a new file element
        suppEl.build { |xml|
          xml.file(path:partialUploadedPath) {
            xml.mimeType uploadedMimeType
            xml.fileSize SubiGuts.getHumanSize(uploadedPath)
          }
        }
      end
    end

    # If we had to force a content file into supp, note it as an item fault.
    if forcedSupp
      recordFault(ark, false, 'no_document',
                  "User '#{who}' uploaded non-doc file '#{filename}' as document for Elements pub #{pubID} (#{ark}). " +
                  "Treated as a supp file. We need to review this item.")
    end

    # If a license has been granted, publish the item.
    approveItem(ark, who, true) if isGranted(ark)

    # All done. Return 201 per sword spec.
    [201, [responseText]]

  rescue FaultRecorded => exc
    # If fault was recorded already, just return a 406 so Elements knows something went wrong.
    createSwordError(406,exc)
  rescue Exception => exc
    recordConnectorError(ark, $!, $@)
    # createSwordError creates the block of SWORD XML that contains errors in the format that Elements
    # expects, according to the examples in the DSpace connector code they sent us.
    # HTTP 406 means "Not acceptable", which, whatever, seems ok.
    createSwordError(406,exc)
  end
end


###################################################################################################
def createSwordError(code,exc)

string = %{
<sword:error xmlns="http://www.w3.org/2005/Atom"
	   xmlns:sword="http://purl.org/net/sword/"
	   xmlns:pubs="http://www.symplectic.co.uk/publications/atom-api"
		href="http://www.symplectic.co.uk/publications/atom-api/ServiceTransactionError">

	<!-- title of the error document -->
	<title>Repository Connector Error</title>

	<!-- When the error was thrown.  That is, NOW! -->
	<updated>#{DateTime.now.iso8601}</updated>

	<!-- Categorisation describing what kind of error this is -->
	<category scheme="http://www.symplectic.co.uk/publications/atom-terms/1.0"
			  term="http://www.symplectic.co.uk/publications/atom-terms/1.0/service-transaction-error"
			  label="Service Transaction Error" />

	<!-- Required SWORD field containing some generic treatment information -->
	<sword:treatment>A repository error occured.</sword:treatment>

	<summary>A repository error occured.</summary>
</sword:error>
}

# Picking apart "exc.to_s.encode(:xml => :text)" it means: take exception, convert it to a string ("to_s"),
# encode that string as XML (so, escape '>' etc)

# logging
puts string

# This is a Sinatra method that stores away the content type for when we eventually return, and
# Sinatra will shove it into the HttpResponse.
content_type("application/atom+xml;type=error")

return [code,string]

end

###################################################################################################
# Find the best version of a file. E.g. if subPath is "content/base.meta.xml", we will search:
#   mainDir/.../item/content/base.meta.xml
#   mainDir/.../item/next/content/base.meta.xml
#   sequesterDir/.../item/content/base.meta.xml
#   sequesterDir/.../item/next/content/base.meta.xml
# Returns the first found, or nil if none are found.
def arkToBestFile(ark, subPath)
  # Next dir
  path = arkToFile(ark, "next/#{subPath}")
  return path if File.file? path

  # Main dir
  path = arkToFile(ark, subPath)
  return path if File.file? path

  # Sequester versions of those
  if SubiGuts.isSequestered(ark)
    path = arkToFile(ark, "next/#{subPath}").sub('/data/', '/data_sequester/')
    return path if File.file? path

    path = arkToFile(ark, subPath).sub('/data/', '/data_sequester/')
    return path if File.file? path
  end

  # Not found
  return nil
end

###################################################################################################
def respondToFileGet(shortArk, dir, filename)
  begin
    ark = "ark:13030/#{shortArk}"
    path = arkToBestFile(ark, "#{dir}/#{sanitizeFilename(filename)}")
    path or halt(404)
    content_type SubiGuts.guessMimeType(path)
    File.open(path, "r") { |f| f.read }
  rescue
    recordConnectorError(shortArk, $!, $@)
    raise
  end
end

###################################################################################################
get "/license/:shortArk/:fileName" do |shortArk, filename|
  respondToFileGet(shortArk, "meta/license", filename)
end

###################################################################################################
get "/content/:shortArk/:fileName" do |shortArk, filename|
  respondToFileGet(shortArk, "content", filename)
end

###################################################################################################
get "/supp/:shortArk/:fileName" do |shortArk, filename|
  respondToFileGet(shortArk, "content/supp", filename)
end

###################################################################################################
def respondToFileDelete(shortArk, dir, filename, editAndApprove)
  begin
    ark = "ark:13030/#{shortArk}"
    isModifiableItem(ark) or
      raise "Cannot use Elements to change an item imported from eSchol unless it's a campus postprint"
    if editAndApprove
      editItem(ark)
      path = arkToFile(ark, "next/#{dir}/#{sanitizeFilename(filename)}")
    else
      path = arkToFile(ark, "#{dir}/#{sanitizeFilename(filename)}")
    end
    File.exists? path or halt(404)

    # Filter out old metadata about this file
    if editAndApprove
      editXML(arkToFile(ark, "next/meta/base.meta.xml")) do |meta|
        partialPath = path.sub(%r{.*/content/}, "content/")
        meta.xpath("content/file[@path='#{partialPath}']").remove
        meta.xpath("content/supplemental/file[@path='#{partialPath}']").remove
        # If all supp files removed, get rid of the surrounding element too.
        meta.xpath("content/supplemental").each { |el| el.remove if el.elements.empty? }
      end
    end

    # Now remove the file itself.
    File.delete path
    approveItem(ark) if editAndApprove and isGranted(ark)

    # Note: the Sword spec says we should respond with a 204, but Elements
    # is unhappy with that, so we return a 200 instead.
    [200, ["Deleted."]]
  rescue
    recordConnectorError(shortArk, $!, $@)
    raise
  end
end

###################################################################################################
def recordConnectorError(ark, info, stack)
  # Include call stack, but remove gems to make it easier to parse by humans
  filteredStack = stack.reject { |ent| ent =~ /\/gems\// }
  recordFault(ark ? ark : "nil", true, 'connector_error',
              "An unhandled exception occurred while processing a POST from Elements to eScholarship. " +
              "This probably indicates a bug. More info: #{info.inspect} at #{filteredStack}.join('; ')}")
end

###################################################################################################
delete "/license/:shortArk/:fileName" do |shortArk, filename|
  begin
    if filename =~ /no_revoke/
      # Need to remove the association between the Elements pub and the eschol item in the eschol_equiv table in oap.db,
      # then return *without* withdrawing the eSchol item.
      filename =~ /.*-(\d+)$/ or raise("PubID not found on synthetic no_revoke license string??")
      fromPubID = $1
      $oapDb.execute("DELETE FROM eschol_equiv WHERE pub_id = ?", fromPubID)
      return [200, ["Deleted."]]
    elsif filename =~ /synthetic_license/
      puts "Skipping delete - synthetic license."
    else
      respondToFileDelete(shortArk, "meta/license", filename, false)
    end

    # Removing a license file means it's "revoked" in Elements. Let's withdraw it on the
    # escholarship side too.
    puts "Withdrawing item from eScholarship."
    checkCall("#{$controlDir}/tools/withdrawItem.py -yes " +
              "-m 'Withdrawn by request of author, editor, or administrator.' #{shortArk}")
  rescue
    recordConnectorError(shortArk, $!, $@)
    raise
  end
end

###################################################################################################
delete "/content/:shortArk/:fileName" do |shortArk, filename|
  respondToFileDelete(shortArk, "content", filename, true)
end

###################################################################################################
delete "/supp/:shortArk/:fileName" do |shortArk, filename|
  respondToFileDelete(shortArk, "content/supp", filename, true)
end

###################################################################################################
def findLicensePath(dirPath)
  # Process each file in the directory (though there should only be one)
  return unless File.directory? dirPath
  return Dir.entries(dirPath).map{|fn| "#{dirPath}/#{fn}"}.select{|path| File.file? path }[0]
end

###################################################################################################
def genLicenseEntry(xml, ark, licensePath, pubID)
  return unless licensePath

  xml.entry {

    # Give the mime type and a download link for the file.
    fn = File.basename(licensePath)
    url = (licensePath =~ /no_revoke/) ? "#{$server}/license/#{getShortArk(ark)}/no_revoke_#{fn}-#{pubID}" :
                                         "#{$server}/license/#{getShortArk(ark)}/#{fn}"
    xml.content type: SubiGuts.guessMimeType(fn), src: url

    # Categorisation describing this entry as a license file
    xml.category scheme: "http://www.symplectic.co.uk/publications/atom-terms/1.0",
                 term:   "http://www.symplectic.co.uk/publications/atom-terms/1.0/licence-file",
                 label:  "Licence File"

    # Unique identifier for this file within the repository
    xml.id_ "#{getShortArk(ark)}/license/#{fn}"

    # Date this file was last modified
    if File.exists? licensePath
      xml.updated File.mtime(licensePath).to_datetime.iso8601
    end

    # The file name
    xml.title fn

    # Link to delete the file
    xml.link rel: 'media-edit', href: url
  }
end

###################################################################################################
# Given a <file> entry in a UCI file, gyrate to obtain the path to the real file on the filesystem.
# Handle old-style paths and sequestered files if necessary.
def pathFromFileMeta(ark, itemDir, fileMeta)
  fileMeta or return nil

  # Prefer to tell the user their original ('native') uploaded file
  fileMeta = fileMeta.at('native') if fileMeta.at('native')

  # Some crazy items don't have a path. Skip them.
  origPath = fileMeta.attr('path')
  origPath or return nil

  # Hack to handle old-style full paths
  partPath = origPath.sub(%r{.*/content/}, '/content/')

  fullPath = "#{itemDir}/#{partPath}"
  if !File.file?(fullPath) && fullPath.include?('/content/') && SubiGuts.isSequestered(ark)
    fullPath.sub! '/data/', '/data_sequester/'
  end

  File.file? fullPath or return nil
  return fullPath
end

###################################################################################################
# Given a <file> entry in a UCI file, gyrate to obtain the just the filename part.
def filenameFromFileMeta(fileMeta)
  fileMeta or return nil

  # Some crazy items don't have a path. Skip them.
  origPath = fileMeta.attr('path')
  if !origPath
    fileMeta = fileMeta.at('native') if fileMeta.at('native')
    origPath = fileMeta.attr('path')
  end
  origPath or return nil

  # Hack to handle old-style full paths
  partPath = origPath.sub(%r{.*/content/}, '/content/')
  return partPath.sub(%r{/?content/}, "")
end

###################################################################################################
def genFileEntries(xml, ark, url, itemDir, fileMetas, extPubVersion, isSupp, embargoDate)

  shortArk = getShortArk(ark)

  # Process each file in the metadata
  usedPaths = Set.new
  fileMetas.each do |fileMeta|

    fullPath = pathFromFileMeta(ark, itemDir, fileMeta)
    next unless fullPath

    # One item has the same filename twice. Elements doesn't like that, so filter out.
    next if usedPaths.include?(fullPath)
    usedPaths << fullPath

    # Generate the entry
    xml.entry {

      # Give the mime type and a download link for the file.
      fn = File.basename(fullPath)
      fullFn = filenameFromFileMeta(fileMeta)
      if fullFn
        xml.content type: SubiGuts.guessMimeType(fn),
                    src: "#{$previewServer}/filePreview/item/#{shortArk}/content/#{fullFn}"
      end

      # Categorisation describing this entry as a content file
      xml.category scheme: "http://www.symplectic.co.uk/publications/atom-terms/1.0",
                   term:   "http://www.symplectic.co.uk/publications/atom-terms/1.0/content-file",
                   label:  "Content File"

      # Unique identifier for this file within the repository
      xml.id_ "#{shortArk}/#{isSupp ? "supp" : "content"}/#{fn}"

      # Date this file was last modified
      xml.updated File.mtime(fullPath).to_datetime.iso8601

      # The file name
      xml.title fn

      # Version info
      xml.send('pubs:file-info') {
        if isSupp
          xml.send('pubs:file-version', "Supporting information")
        elsif extPubVersion == "authorVersion"
          xml.send('pubs:file-version', "Author final version")
        elsif extPubVersion == "publisherVersion"
          xml.send('pubs:file-version', "Published version")
        end

        # puts "embargoDate: #{embargoDate.inspect}"

        if embargoDate # does this check for nil basically?
          xml.send('pubs:availability', "private")
          xml.send('pubs:date-available', embargoDate)
        else
          xml.send('pubs:availability', "public")
        end
      }

      # Link to delete the file
      xml.link rel: 'media-edit', href: "#{$server}/#{isSupp ? "supp" : "content"}/#{shortArk}/#{fn}"

      # rel:self link -- we're not sure yet what Elements uses this for
      #reallyShortArk = shortArk.sub(/^qt/, "")
      #xml.link rel: 'self', href: "#{$publicServer}/uc/item/#{reallyShortArk}.pdf?preview=1&origin=elements"
    }
  end
end

###################################################################################################
def genEntries(xml, ark, itemDir, meta, pubID)

  # An entry for the license file
  licensePath = itemDir ? findLicensePath("#{itemDir}/meta/license") : nil
  if licensePath && meta.attr('state') != 'withdrawn'
    xml.send('pubs:licence-count', 1)
    genLicenseEntry(xml, ark, licensePath, pubID)
    xml.published File.mtime(licensePath).to_datetime.iso8601
    xml[:pubs].status("accepted")
  elsif meta.attr('state') == 'published' || !itemDir
    # Handle items imported directly from eScholarship. To make it show as "live" in Elements,
    # we need to synthesize a license file entry.
    xml.send('pubs:licence-count', 1)
    licensePath = (itemDir ? itemDir : "no_revoke") + "/meta/license/synthetic_license"
    genLicenseEntry(xml, ark, licensePath, pubID)
    xml.published meta.attr('stateDate')
    xml[:pubs].status("accepted")
  else
    xml[:pubs].status("inworkspace")
  end

  # An entry for each file. The file links will all go to the item.
  if itemDir
    url = "#{$previewServer}/filePreview/item/#{getShortArk(ark)}"
    genFileEntries(xml, ark, url, itemDir, meta.xpath("content/file"),
                   meta.attr('externalPubVersion'), false, meta.attr('embargoDate'))
    genFileEntries(xml, ark, url, itemDir, meta.xpath("content/supplemental/file"),
                   nil, true, meta.attr('embargoDate'))
  end
end

###################################################################################################
def calcEscholURL(ark, preview)
  shortArk = getShortArk(ark)
  tinyArk = shortArk.sub(/^qt/,'')
  return preview ? "#{$previewServer}/filePreview/item/#{tinyArk}" :
                   "#{$publicServer}/uc/item/#{tinyArk}"
end

###################################################################################################
get '/preview/:shortArk' do |shortArk|

  # Find the metadata
  ark = "ark:/13030/#{shortArk}"
  metaPath = arkToBestFile(ark, "meta/base.meta.xml")
  metaPath or halt(404)
  File.exists?(metaPath) or halt(404)

  # Read the metadata
  io = File.open(metaPath, "r")
  meta = Nokogiri::XML(io).root
  io.close

  # Is this item published or preview?
  preview = (meta.attr('state') =~ /new|pending/)

  # Now form a URL for it.
  url = calcEscholURL(ark, preview)

  # All done. Send a page that will redirect to the right place.
  # Note: We don't use an HTTP redirect in this case, because Elements will follow it directly, and then
  # load the target page with the wrong URL path context.
  # Rather, we want the user's *browser* to follow the redirect, so that it will show up with proper context.
  """
    <html>
      <head>
        <meta http-equiv='refresh' content='0; url=#{url}' />
      </head>
      <body>
        Redirecting to: #{url}
      </body>
    </html>
  """
end

###################################################################################################
def genUCIEntry(xml, pubID, ark, metaPath, meta, itemDir)

  # Title of the item
  xml.title meta.at("title").text if meta.at("title")

  # Link for editing. We don't really have that, do we? This one is invented.
  xml.link rel: "media-edit", href: "#{$server}/edit/#{pubID}"

  # Categorisation marking this as a Repository Item
  xml.category scheme: "http://www.symplectic.co.uk/publications/atom-terms/1.0",
               term:   "http://www.symplectic.co.uk/publications/atom-terms/1.0/repository-item",
               label:  "Repository Item"

  # Authors
  meta.xpath("authors/author").each do |auth|
    xml.author {
      xml.name "#{auth.at('lname').text}, #{auth.at('fname').text}"
    }
  end

  # Identifier of the publication (apparently, this has to be the ID within Elements)
  xml.id_ pubID

  # When this record was last updated
  xml.updated File.mtime(metaPath).to_datetime.iso8601

  # The URI of the web service which generated this list
  xml.generator("eScholarship", uri: "#{$server}/connector")

  # The URI of the repository item record (MUST be the public url).  The
  # public url SHOULD appear in the pubs:summary/pubs:public-url elements
  shortArk = getShortArk(ark)
  publicURL = "#{$publicServer}/uc/item/#{shortArk.sub(/^qt/, '')}"
  xml.link rel: "alternate", href: publicURL

  xml.send('pubs:public-url', publicURL)

  # Special section for summary. Not sure why stuff is dupe'd here, but whatever.
  xml[:pubs].summary {
    xml[:pubs].id_ pubID

    subDate = meta.at('history/submissionDate')
    xml.send('pubs:created-date', "#{subDate.text}T00:00:00-0700") if subDate

    # special behavior in support of auto deposit via xml batch
    if (meta.xpath("//context/localID[@type='oa_harvester']").length > 0) &&
       (meta.xpath("//context/publishedWebLocation").length > 0) &&
       (meta.xpath("//content//file").length == 0)
      xml.send('pubs:file-count', 1)
      # We also need to add an element here for oa-location, but are waiting on an answer
      # from Symplectic on how to do that.
    else
      xml.send('pubs:file-count', itemDir ? meta.xpath('content//file').length : 0)
    end

    licenseDir = "#{itemDir}/meta/license"
    if File.directory? licenseDir
      licenseCount = itemDir ? Dir.entries(licenseDir).select{|f| File.file? "#{licenseDir}/#{f}"}.length : 1
      xml.send('pubs:licence-count', licenseCount)
      xml.send('pubs:public-url', publicURL)
    end

    # Entries for the license and content files
    ## NOTE! The sample feed from Symplectic puts these inside pubs:file-holdings.
    ##       However when we tried that, deposited publications showed as status "Unknown"
    ##       rather than "Live". Go figger.
    #xml.send('pubs:file-holdings') {
      genEntries(xml, ark, itemDir, meta, pubID)
    #}
  }

  # Entries for the license and content files
  genEntries(xml, ark, itemDir, meta, pubID)
end

###################################################################################################
def genUCIFeed(pubID, ark, metaPath, meta, itemDir)
  Nokogiri::XML::Builder.new(encoding: 'UTF-8') { |xml|
    xml.feed('xmlns' => "http://www.w3.org/2005/Atom",
              'xmlns:pubs'  => "http://www.symplectic.co.uk/publications/atom-api") {

      genUCIEntry(xml, pubID, ark, metaPath, meta, itemDir)
    }
  }.to_xml
end

###################################################################################################
get '/connector/publication/:id' do |pubID|

  # If the user has recorded an equivalent publication in eSchol, we will synthesize info for it.
  equivArk = $oapDb.get_first_value("SELECT eschol_ark FROM eschol_equiv WHERE pub_id = ?", pubID)

  # Figure out the ARK. If not found, return a 404.
  ark = equivArk ? equivArk : arkForPub(pubID)
  ark or halt(404)

  # Make sure there's a metadata file.
  metaPath = arkToFile(ark, "next/meta/base.meta.xml")
  File.file? metaPath or metaPath = arkToFile(ark, "meta/base.meta.xml")
  File.exists? metaPath or halt(404)

  # If it's a light 'equivalence' relationship, don't give a full file list.
  itemDir = equivArk ? nil : getRealPath("#{metaPath}/../..")

  # Read the metadata
  io = File.open(metaPath, "r")
  meta = Nokogiri::XML(io).root
  io.close

  # Cool. Hand back an ATOM feed with details about this item.
  content_type "application/atom+xml;type=feed"
  return genUCIFeed(pubID, ark, metaPath, meta, itemDir)
end

###################################################################################################
def sendNewApprovalEmail(ark, depositorEmail)

  # We need to know the campus(es) of the author(s)
  feedPath = arkToFile(ark, 'meta/base.feed.xml')
  feed = fileToXML(feedPath).remove_namespaces!
  feed = feed.root
  campuses = determineCampuses(feed)

  # Need to find the publication date and title
  meta = fileToXML(arkToFile(ark, 'meta/base.meta.xml'))
  pubDate = meta.text_at('//history/originalPublicationDate')
  title = meta.text_at('title')

  # Calculate the URL for this pub on eScholarship
  url = calcEscholURL(ark, false)

  # On dev and stage, don't send to the real people.
  if !($hostname == 'pub-submit-prd-2a' || $hostname == 'pub-submit-prd-2c')
    depositorEmail = 'kirk.hastings@ucop.edu'
    authorEmail = 'kirk.hastings@ucop.edu'
  end

  sender = 'oa-no-reply@universityofcalifornia.edu'
  recipients = [depositorEmail.strip]

  # Justin would like is to change the email address in the body to match the campus:
  # "it’d be *better* if the email address in the signature wasn’t ours, but idk if
  # you could dynamically insert the campus support address depending upon the
  # depositor’s primary group (?)"

  text = """\
    From: #{sender}
    To: #{recipients.join(', ').sub(%r{^[\s,]+}, '').sub(%r{[\s,]+$}, '')}
    MIME-Version: 1.0
    Content-type: text/html
    Subject: Your article has been successfully deposited in eScholarship

    <html>
      <body>
        <p>Congratulations! This email confirms that you have successfully uploaded a version of your publication
           <b>“#{title}”</b> to eScholarship, UC’s open access repository and publishing platform.
        </p>
        <p>View your publication here: <a href='#{url}'>#{url}</a></p>
        <p>You will receive monthly usage reports for this publication and any others you submit to eScholarship.</p>
        <p>To manage your deposited publications or add additional new ones, return to the
           <a href='http://oapolicy.universityofcalifornia.edu/'>UC Publication Management System</a>,
           a tool developed to support open access policy participation at UC. You can learn more about
           UC’s OA policies at the <a href='http://uc-oa.info'>Office of Scholarly Communication</a>.
        </p>
        <p>Questions? Contact us:
           <a href='mailto:oapolicy-help@universityofcalifornia.edu'>oapolicy-help@universityofcalifornia.edu</a>
        </p>
      </body>
    </html>
    """.unindent

  puts "Sending new approval email:"
  puts text

  begin
    Net::SMTP.start('localhost') do |smtp|
      smtp.send_message(text, sender, recipients.to_a)
    end
  rescue Exception => e
    puts "Warning: unable to send email: #{e}"
  end
end

###################################################################################################
def approveItem(ark, who=nil, okToEmail=true)

  # Before starting, determine if this is a new item.
  path = arkToFile(ark, 'meta/base.meta.xml', true)
  isNew = !(File.exist? path)

  # Most of this is rote
  SubiGuts.approveItem(ark, "Submission completed at oapolicy.universityofcalifornia.edu", who)

  # Jam the data into the database, so that immediate API calls will pick it up.
  Bundler.with_clean_env {  # super annoying that bundler by default overrides sub-bundlers environments
    checkCall(["#{$jscholDir}/tools/convert.rb", "--preindex", ark.sub("ark:/13030/", "")])
  }

  # Send email only the first time, and never when we're scanning.
  (isNew && !$scanMode && who && okToEmail) and sendNewApprovalEmail(ark, who)
end

###################################################################################################
def isGranted(ark)

  # For items from Elements, there will be a license file.
  findLicensePath(arkToFile(ark, 'next/meta/license')) and return true

  # For eschol items, check the 'state' attribute in the main metadata
  metaPath = arkToFile(ark, "meta/base.meta.xml")
  File.exists? metaPath or return false
  File.open(metaPath, "r") { |io|
    Nokogiri::XML(io).root.attr('state') == 'published' and return true
  }

  return false
end

###################################################################################################
# Create a 'next' directory for an item, and make it pending there.
def editItem(ark, who=nil, pubID=nil)

  # Skip if the item has never been published.
  return unless File.directory? arkToFile(ark, 'meta')

  # We may be taking ownership of a Subi item, replacing it with Elements. Change
  # the arks databse so that future scans will correctly scan this item.
  if pubID
    $arkDb.execute("UPDATE arks SET external_id=?, source=?, external_url=? WHERE id=?",
      [pubID, 'elements', nil, ark.sub("ark:/", "ark:")])
  end

  # The rest is rote
  SubiGuts.editItem(ark, "Changed on oapolicy.universityofcalifornia.edu", who)
end

###################################################################################################
def authNameKeySingleInitial(authEl)
  data = ""
  authEl.text_at("lname").try { |t| data << t }
  fname = authEl.text_at("fname")
  if fname and fname.length > 0
    data << fname[0]
  end
  return transliterate(data).downcase
end

###################################################################################################
def authNameKeyAllInitials(authEl)
  data = ""
  authEl.text_at("lname").try { |t| data << t }
  fname = authEl.text_at("fname")
  if fname =~ /^[A-Z]{1,3}$/
    data << fname
  elsif fname.length > 0
    data << fname[0]
  end
  return transliterate(data).downcase
end

###################################################################################################
def personNameKeySingleInitial(person)
  data = ""
  person.text_at("last-name").try { |t| data << t }
  initials = person.text_at("initials")
  if initials && initials.length > 0
    data << person.text_at("initials")[0]
  end
  return transliterate(data).downcase
end

###################################################################################################
def personNameKeyAllInitials(person)
  data = ""
  person.text_at("last-name").try { |t| data << t }
  if person.text_at("initials")
    data << person.text_at("initials")
  end
  return transliterate(data).downcase
end

###################################################################################################
def integrateUciAndFeedEmails(uci, recordPeople, feed, authOrEd)
  %{
    It takes a lot of digging and some fuzzy matching to attach email addresses to authors. We
    have data from three potential sources.

    1. People in the Elements feed, who have a relationship with the item of type "pub-user-authorship",
       "pub-user-editorship", etc. They are not part of the data record from Scopus/WOS/etc but only in
       the outer-level feed.

        <person>
          ...snip...
          <initials>M</initials>
          <last-name>Hance</last-name>
          <first-name>Michael</first-name>
          <email-address>mhance@ucsc.edu</email-address>
          <relationships>
            <relationship type="publication-user-authorship">
              ...snip...
            </relationship>
          </relationships>
        </person>
        <person>
          ...snip...
          <initials>AJ</initials>
          <last-name>Lankford</last-name>
          <first-name>Andrew</first-name>
          <email-address>ajlankfo@uci.edu</email-address>
          <relationships>
            <relationship type="publication-user-authorship">
              ...snip...

    2. People in the Scopus/WOS/etc record later in the Elements feed. These may or may not use
       the same initials or form of the name as those above.

        <entry>
          <id>tag:elements@universityofcalifornia/publication/1030446/bib-record/wos-lite</id>
          ...snip...
          <title>Search for Higgs boson pair production in the b(b)over-barb(b)over-bar final state...</title>
          <updated>2016-01-28T14:00:23.917-08:00</updated>
          <bibliographic-data format="native">
            <native>
              <field name="authors" type="person-list" display-name="Authors">
                <people>
                  <person>
                    <last-name>Aad</last-name>
                    <initials>G</initials>
                  </person>
                  ...snip...
                  <person>
                    <last-name>Hance</last-name>
                    <initials>M</initials>
                  </person>
                  ...snip...
                  <person>
                    <last-name>Lankford</last-name>
                    <initials>AJ</initials>
                  </person>
                  ...snip...

    3. "authors" in our pre-existing UC Ingest metadata (if any). Again, they might use different initials.

       <authors>
          <author>
             <fname>G</fname>
             <lname>Aad</lname>
          </author>
          ...snip...
          <author>
             <fname>M</fname>
             <lname>Hance</lname>
             <email>mhance@ucsc.edu</email>
          </author>
          <author>
             <fname>AJ</fname>
             <lname>Lankford</lname>
             <email>ajlankfo@uci.edu</email>
          </author>
          ...snip...

    Our goals are:
      (1) Preserve existing emails if possible from the eScholarship record, so we don't lose stuff
          that was entered via Subi and stored in the existing UC Ingest metadata.
      (2) Match emails from the outer part of the feed to authors inside the records of the feed,
          overriding stuff from the UC I record if necessary.
  }

  # We're going to try and attach each incoming email address to one and only one author in the
  # output.
  #
  # First, let's build a list of all the authors we're going to try to match. These are the ones
  # from the Scopus/WOS/etc record. If by chance there's an email there, record it.
  #
  emailForPerson = {}
  emailsAssigned = Set.new

  # Augment that list with emails from the outer feed.

  ['authorship', 'editorship', 'contributorship', 'translation'].each do |kind|
    feed.xpath("people/person[relationships/relationship/@type='publication-user-#{kind}']").each { |person|
      email = person.text_at("email-address")
      next unless email
      email.strip!
      emailForPerson[personNameKeyAllInitials(person)] = email
      emailForPerson[personNameKeySingleInitial(person)] = email
      emailsAssigned << email.downcase
    }
  end
  #puts "After stage 2: #{emailForPerson.select{|k,v|v}.inspect}"

  # Augment again using emails from the existing UC-Ingest metadata, if any.
  uci.xpath("#{authOrEd}s/#{authOrEd}").each { |el|
    email = el.text_at("email")
    next unless email
    email.strip!
    next if emailsAssigned.include?(email.downcase)
    srcKey1 = authNameKeyAllInitials(el)
    srcKey2 = authNameKeySingleInitial(el)

    emailForPerson[srcKey1] = email
    emailForPerson[srcKey2] = email
    emailsAssigned << email.downcase
  }
  #puts "After stage 3: #{emailForPerson.select{|k,v|v}.inspect}"

  # Now return just the ones that have a non-null value.
  return emailForPerson.select{|k,v|v}
end

###################################################################################################
def transformPeople(uci, metaHash, authOrEd)

  dataBlock = metaHash.delete("#{authOrEd}s") or return

  # Now build the resulting UCI author records.
  uci.find!("#{authOrEd}s").rebuild { |xml|
    person = nil
    dataBlock.split("||").each { |line|
      line =~ %r{\[([-a-z]+)\] ([^|]*)} or raise("can't parse people line #{line.inspect}")
      field, data = $1, $2
      case field
        when 'start-person'
          person = {}
        when 'lastname'
          person[:lname] = data
        when 'firstnames', 'initials'
          if !person[:fname] || person[:fname].size < data.size
            person[:fname] = data
          end
        when 'email-address', 'resolved-user-email'
          person[:email] = data
        when 'resolved-user-orcid'
          person[:orcid] = data
        when 'identifier'
          puts "TODO: Handle identifiers like #{data.inspect}"
        when 'end-person'
          if !person.empty?
            puts "Sending person #{person.inspect}"
            xml.send(authOrEd) {
              person[:fname] and xml.fname(person[:fname])
              person[:lname] and xml.lname(person[:lname])
              person[:email] and xml.email(person[:email])
              person[:orcid] and xml.identifier(:type => 'ORCID') { |xml| xml.text person[:orcid] }
            }
          end
          person = nil
        when 'address'
          # e.g. "University of California, Berkeley\nBerkeley\nUnited States"
          # do nothing with it for now
        else
          raise("Unexpected person field #{field.inspect}")
      end
    }
  }
end


###################################################################################################
# Determine which campus(es) are associated with the given publication feed. The info in
# organisational-details/group seems to be really reliable for this (as opposed to eppn suffixes).
def determineCampuses(feed)
  campuses = Set.new
  feed.xpath("//organisational-details/group").each { |group|
    group.text.split("/").each { |part|
      $campusNames[part] and campuses << $campusNames[part]
    }
  }
  return campuses
end

###################################################################################################
# Figure out the author, editor, contributor or translator affecting this article. Pick the
# first one we find searching in that order.
def findAuthorPerson(feed)
  feed.xpath("people/person[relationships/relationship/@type='publication-user-authorship'][1]")[0] ||
  feed.xpath("people/person[relationships/relationship/@type='publication-user-editorship'][1]")[0] ||
  feed.xpath("people/person[relationships/relationship/@type='publication-user-contributorship'][1]")[0] ||
  feed.xpath("people/person[relationships/relationship/@type='publication-user-translation'][1]")[0]
end

###################################################################################################
# Take feed XML from Elements and make a UCI record out of it. Note that if you pass existing UCI
# data in, it will be retained if Elements doesn't override it.
# NOTE: UCI in this context means "UC Ingest" format, the internal metadata format for eScholarship.
# Options: ark, fileVersion
def uciFromFeed(uci, feed, **opt)

  # Parse out the flat list of metadata from the feed
  metaHash = {}
  feed.xpath(".//metadataentry").each { |ent|
    key = ent.text_at('key')
    value = ent.text_at('value')
    metaHash.key?(key) and raise("double key #{key}")
    metaHash[key] = value
  }

  # The easy top-level attributes
  if opt[:ark]
    uci[:id] = uci[:id] || opt[:ark].sub(%r{ark:/?13030/}, '')
  end
  ark = uci[:id]
  uci[:dateStamp] = DateTime.now.iso8601
  uci[:peerReview] = uci[:peerReview] || 'yes'
  uci[:state] = uci[:state] || 'new'
  uci[:stateDate] = uci[:stateDate] || DateTime.now.iso8601

  # Figure out the publication ID
  pubID = metaHash.delete('elements-pub-id') or raise("can't find pub ID in feed")

  # Publication type is a bit tricky
  pubTypeStr = metaHash.delete('object.type') or raise("metadata missing object.type")
  uci[:type] = case pubTypeStr
    when %r{^(journal-article|conference-proceeding|internet-publication|scholarly-edition|report)$}; 'paper'
    when %r{^(dataset|poster|media|presentation|other)$}; 'non-textual'
    when "book"; 'monograph'
    when "chapter"; 'chapter'
    else raise "Can't recognize pubType #{pubTypeStr.inspect}" # Happens when Elements changes or adds types
  end


  # Author and editor metadata. Use the preferred record if specified.
  transformPeople(uci, metaHash, 'author')
  transformPeople(uci, metaHash, 'editor')

  # Other top-level fields
  uci.find!('source').content = 'oa_harvester'
  metaHash.key?('title') and uci.find!('title').content = metaHash.delete('title')
  ##record.at(".//field[@name='abstract']/text").try { |e| uci.find!('abstract').content = e.text }
  ##record.at(".//field[@name='doi']").try { |e| uci.find!('doi').content = e.text }
  ##record.xpath(".//field[@name='pagination'][1]/pagination").each { |pg|
  ##  uci.find!('extent').rebuild { |xml|
  ##    pg.at("begin-page").try { |e| xml.fpage e.text }
  ##    pg.at("end-page").try { |e| xml.lpage e.text }
  ##  }
  ##}
  ##record.at(".//field[@name='keywords'][1]/keywords").try { |outer|
  ##  uci.find!('keywords').rebuild { |xml|
  ##    outer.xpath("keyword").each { |kw|
  ##      xml.keyword kw.text
  ##    }
  ##  }
  ##}

  # Things that go inside <context>
  contextEl = uci.find! 'context'
  oldEntities = contextEl.xpath(".//entity").dup    # record old entities so we can reconstruct and add to them
  contextEl.rebuild { |xml|
      xml.localID(:type => 'oa_harvester') {
        xml.text pubID
      }
      metaHash.key?("oa-location-url") and xml.publishedWebLocation(metaHash.delete("oa-location-url"))
  }

  # Things that go inside <history>
  who = metaHash.delete('depositor-email') or raise("metadata missing depositor-email")
  history = uci.find! 'history'
  history[:origin] = 'oa_harvester'
  history.at("escholPublicationDate") or history.find!('escholPublicationDate').content = Date.today.iso8601
  history.at("submissionDate") or history.find!('submissionDate').content = Date.today.iso8601
  dateIssued = metaHash.delete('date.issued') or raise("metadata missing 'date.issued'")
  dateIssued =~ /^20\d\d-[01]\d-[0123]\d$/ or raise("Unrecognized date.issued format: #{dateIssued.inspect}")
  history.find!('originalPublicationDate').content = dateIssued
  if !history.at("stateChange")
    history.build { |xml|
      xml.stateChange(:state => 'new',
                      :date  => DateTime.now.iso8601,
                      :who   => who) {
        xml.comment_ "Claimed at oapolicy.universityofcalifornia.edu"
      }
    }
  end
end

def addUniqueEntity (contextEl, id, label, type, entsAdded)
  if !entsAdded.include?(id)
    contextEl.build { |xml|
      xml.entity(id: id, entityLabel: label, entityType: type)
    }
    entsAdded << id
  end
end

# extending Date class
class Date
  def self.parsable?(string)
    begin
      parse(string)
      true
    rescue ArgumentError
      false
    end
  end
end

###################################################################################################
def scanAllChanges(startPage)

  # Find out when the previous scan was performed. Also, note the time of this scan.
  path = "#{$scriptDir}/scanState.yaml"
  scanState = File.exists?(path) ? YAML.load_file(path) : {}
  lastScan = scanState['lastScanTime']
  lastScan and lastScan = DateTime.iso8601(lastScan)
  scanStart = DateTime.now

  # Form the URL for getting the first page of changed pubs in Elements. Back the time off
  # by 90 minutes in case the server clocks are sloppy.
  # removing page-size. it causes performance problems
  #pageSize = 200
  if $onlyPub
    url = "#{$repoToolsAPI}/publication/#{$onlyPub}"
  else
    # removing page-size. it causes performance problems
    #url = "#{$repoToolsAPI}/list-publications?page=#{startPage}&per-page=#{pageSize}"
    url = "#{$repoToolsAPI}/list-publications?page=#{startPage}"
    lastScan and url += "&from=#{CGI.escape((lastScan - (1.5/24)).iso8601)}"
  end

  # Read in credentials we'll need to connect to the API
  credentials = Netrc.read
  elemServer = url[%r{//([^/:]+)}, 1]
  user, passwd = credentials[elemServer]
  passwd or raise("No credentials found in ~/.netrc for machine '#{elemServer}'")

  totalScanElapsed = 0
  totalScanned = 0

  # Now scan through each page
  uri = URI(url)
  Net::HTTP.start(uri.hostname, uri.port, :read_timeout => 600, :use_ssl => uri.scheme == 'https') { |http|
    while url
      totalScanned > 0 and puts "Avg scan time: #{totalScanElapsed / totalScanned}"
      puts "#{DateTime.now.iso8601}: #{url}"
      # We remove namespaces below because it just makes everything easier.
      feedData = Nokogiri::XML(httpGetWithRetry(http, url, user, passwd)).remove_namespaces!.root
      if $onlyPub
        scanPub(http, feedData, user, passwd)
      else
        feedData.xpath("entry").each { |ent|
          scanStartTime = Time.now.to_f
          begin
            scanPub(http, ent, user, passwd)
          rescue Exception => exc
            puts "Warning: Exception while processing pub #{ent.xpath("id").select{|el|
                   el.text =~ /^\d+$/}[0].text}: #{exc.inspect}. Backtrace: #{exc.backtrace.join(". ")}"
          end
          scanElapsed = Time.now.to_f - scanStartTime
          totalScanElapsed += scanElapsed
          totalScanned += 1
        }
      end
      url = feedData.at("link[rel='next']/@href").try{|hr| hr.to_s}
    end
  }

  # Now that we've finished the scan, update the time and save it (unless we're in test mode)
  if not $onlyPub
    scanState['lastScanTime'] = scanStart.iso8601
    $testMode or File.open(path, 'w') {|io| io.write scanState.to_yaml }
  end
  puts "Scan complete."
end

###################################################################################################
def emailStaffAboutScanFailure(exc)
  # Don't email about Interrupt exceptions, since presumably a person hit Ctrl-C.
  return if exc.inspect.include? "Interrupt"

  sender = 'oa-no-reply@universityofcalifornia.edu'
  recipients = ["martin.haye@ucop.edu", "kirk.hastings@ucop.edu"]

# DO NOT INDENT BELOW
text = """From: #{sender}
To: martin.haye@ucop.edu, kirk.hastings@ucop.edu
MIME-Version: 1.0
Content-type: text/html
Subject: Connector scan failed

<html>
  <body>
    <p>The connector scan failed.</p>
    <p>Detail: #{exc.inspect.encode(:xml => :text)}</p>
    <p>Backtrace: #{exc.backtrace.map{ |s| s.encode(:xml => :text) }.join("<br />\n")}</p>
    <p>Log for more info: /apps/eschol/apache/logs/elemScan.log</p>
  </body>
</html>
"""
# DO NOT INDENT ABOVE

  puts "Sending failure email."
  puts text

  begin
    Net::SMTP.start('localhost') do |smtp|
      smtp.send_message(text, sender, recipients.to_a)
    end
  rescue Exception => e
    puts "Warning: unable to send email: #{e}"
  end
end

###################################################################################################
def emailStaffAboutMerge(fromPubID, fromArk, toPubID, toArk, who)

  sender = 'oa-no-reply@universityofcalifornia.edu'
  # NOTE NOTE NOTE: We want to change this to the appropriate SalesForce address, instead of Kirk.
  #                 Justin says use oapolicy-help@universityofcalifornia.edu
  #                 He approves of the subject line and will use a filter to put it in my queue

  recipients = ["kirk.hastings@ucop.edu"]

  shortFromArk = getShortArk(fromArk).sub(/^qt/, "")
  shortToArk = getShortArk(toArk).sub(/^qt/, "")

# DO NOT INDENT BELOW
text = """From: #{sender}
To: kirk.hastings@ucop.edu
MIME-Version: 1.0
Content-type: text/html
Subject: Merge performed in Elements needs withdraw/redirect in eScholarship

<html>
  <body>
    <p>User #{who} merged Elements publication #{fromPubID}, corresponding to eSchol ark #{fromArk}
    to Elements publication #{toPubID}, corresponding to eSchol ark #{toArk}.
    </p>
    <ol>
      <li>ssh eschol@#{$sshTarget}</li>
      <li>erepfind #{fromArk}, then M for metadata. Note affiliation of item being withdrawn</li>
      <li>erepfind #{toArk}, then M for metadata, then V for vi.
          We are going to change this item to be multiple-affiliation.
          Edit the &ltcontext&gt element in the metadata file for #{shortToArk} to add the affiliation
          (unless it's already there). Which one should be primary? The non-campus-postprint series.
          Else, guess, or ask Justin</li>
      <li>cd erep/xtf/control/tools</li>
      <li>./withdrawItem.py -m \"Item merged in Elements\" #{fromArk}</li>
      <li>Go to: <a href=\"https://escholarship.org/login\">https://escholarship.org/login</a> and
          log in as help@escholarship.org</li>
      <li>Go to Home page and click 'About eSchol', then click the 'Edit Page' button, followed by
          'Sitewide Redirects' and then 'item'</li>
      <li>Scroll to the bottom of the page and add redirect:</li>
      <li>From: /uc/item/#{shortFromArk}, To: /uc/item/#{shortToArk}, Descrip: Item merged in Elements</li>
      <li>Click 'Add'</li>
    </ol>
  </body>
</html>
"""
# DO NOT INDENT ABOVE

  puts "Sending staff email."
  puts text

  begin
    Net::SMTP.start('localhost') do |smtp|
      smtp.send_message(text, sender, recipients.to_a)
    end
  rescue Exception => e
    puts "Warning: unable to send email: #{e}"
  end
end

###################################################################################################
def applyMergeUpdates(fromPubID, fromArk, toPubID, toArk, feedMeta, who)

  # Print out what we're doing, not only as a record but also in case it crashes before finishing.
  puts ""
  puts "Applying merge updates: fromPubID=#{fromPubID} fromArk=#{fromArk} toPubID=#{toPubID} toArk=#{toArk} who=#{who}"

  # Now we need to update the metadata file, which records the Elements pubID in the <localID> field.
  # First, create a next directory if the item has been published
  if fromArk
    puts "Updating localID in eSchol metadata."
    editItem(fromArk, who, fromPubID)

    # Replace the localID within the context element
    editXML(arkToFile(fromArk, "next/meta/base.meta.xml")) do |meta|
      contextEl = meta.find! 'context'
      contextEl.search("./localID[@type='oa_harvester']").remove
      contextEl.build { |xml|
        xml.localID(:type => 'oa_harvester') {
          xml.text toPubID
        }
      }
    end

    # If a license has been granted, publish the item.
    approveItem(fromArk, who) if isGranted(fromArk)
  end

  # In our databases, change old references to new references
  puts "Updating arks database."
  if fromArk and toArk
    # avoid two records in ark database with same external_id
    $arkDb.execute("UPDATE arks SET external_id=? WHERE source='elements' AND external_id=?", ["merged:" +
                   fromPubID + "->" + toPubID, fromPubID])
  else
    $arkDb.execute("UPDATE arks SET external_id=? WHERE source='elements' AND external_id=?", [toPubID, fromPubID])
  end
  puts "Updating oap database."

  $oapDb.execute("UPDATE pubs SET pub_id=? WHERE pub_id=?", [toPubID, fromPubID])

  if toArk
    $oapDb.execute("DELETE FROM eschol_equiv WHERE pub_id = ?", fromPubID)
  else
    existing = $oapDb.get_first_value("SELECT pub_id FROM eschol_equiv WHERE pub_id = ?", toPubID)
    if existing
      $oapDb.execute("DELETE FROM eschol_equiv WHERE pub_id = ?", fromPubID)
    else
      $oapDb.execute("UPDATE eschol_equiv SET pub_id=? WHERE pub_id=?", [toPubID, fromPubID])
    end
  end

  # If merging from an eschol pub to an eschol pub, we need to withdraw and redirect. Sadly,
  # there is no automated way to redirect. So, Kirk has kindly volunteered to fill the gap.
  # Mind the gap Kirk!
  if fromArk && toArk
    puts "Emailing staff about need to redirect."
    emailStaffAboutMerge(fromPubID, fromArk, toPubID, toArk, who)
  end

  puts "Done with merge processing."

end


###################################################################################################
def detectMergeProblem(pubID, ark, feedMeta, who)
  if feedMeta.at('.//merge-history/merge-from')
    toPubID = pubID
    toArk = ark
    fromPubID = feedMeta.at('.//merge-history/merge-from/@id').to_s
    fromArk = arkForPub(fromPubID)
    applyMergeUpdates(fromPubID, fromArk, toPubID, toArk, feedMeta, who)
    true
  elsif feedMeta.at('.//merge-history/merge-to')
    fromPubID = pubID
    fromArk = ark
    toPubID = feedMeta.at('.//merge-history/merge-to/@id').to_s
    toArk = arkForPub(toPubID)
    applyMergeUpdates(fromPubID, fromArk, toPubID, toArk, feedMeta, who)
    true
  else
    false
  end
end

###################################################################################################
def recordFault(ark, sendEmail, faultType, descrip)
  cmd = ["#{$controlDir}/tools/recordItemFault.rb"]
  if sendEmail
    cmd << "--email"
  end
  cmd += [faultType, descrip, ark]
  checkCall(cmd)
end

###################################################################################################
def arkForPub(pubID)
  pubID or return nil
  ark = $arkDb.get_first_value("SELECT id FROM arks WHERE source='elements' AND external_id=?", pubID)
  if !ark
    ark = $oapDb.get_first_value(
      "SELECT campus_id FROM ids, pubs WHERE ids.oap_id = pubs.oap_id AND pub_id = ? AND campus_id LIKE 'c-eschol-id::%'",
      pubID)
    ark and ark.sub!('c-eschol-id::', '')
  end
  return ark
end

###################################################################################################
def getPreferredRecord(feed)
  pref = feed.text_at("//people/person/relationships/relationship[@type='publication-user-authorship']/" +
                      "user-preferences/data-source")
  return feed.at("//entry[data-source/source-name = '#{pref}']") || feed.at("//entry[1]") ||
         feed.at("//record[@format='native'][1]")
end

###################################################################################################
def parseSuggestions(suggLink, user, passwd)

  suggestions = nil
  suggMeta = nil

  $apiMutex.synchronize {
    if !$apiConn
      uri = URI(suggLink)
      $apiConn = Net::HTTP.start(uri.hostname, uri.port, :use_ssl => uri.scheme == 'https')
    end
    suggMeta = Nokogiri::XML(httpGetWithRetry($apiConn, suggLink, user, passwd)).remove_namespaces!.root
  }

  begin
    suggMeta.xpath(".//relationship-suggestion").each { |sugg|
      # Suggestion type-id 8 means "authored by" in this context, 9 means "edited by"
      suggType = sugg.attr("type-id")
      next if suggType != "8"  # only retain authored-by suggestion; skip edited-by suggestion (no place to put them)

      suggStatus = sugg.text_at("suggestion-status")
      suggStatus == "pending" or raise("Unexpected suggestions status #{suggStatus.inspect}")

      suggRel = sugg.at("related")
      suggRelType = suggRel.attr("direction")
      suggRelType == "to" or raise("Unexpected suggestion relation direction #{suggRelType.inspect}")

      suggRelObj = suggRel.at("object")
      suggRelObjCat = suggRelObj.attr("category")
      suggRelObjCat == "user" or raise("Unexpected suggestion relation object category #{suggRelCat.insepct}")

      suggRelUser = suggRelObj.attr("username")
      (suggRelUser && suggRelUser.include?("@")) or
        raise("Expecting email address for suggestion relation but got #{suggRelUser.inspect}")

      suggestions ||= Array.new
      suggestions.include?(suggRelUser) or suggestions << suggRelUser
    }

    return suggestions
  rescue
    puts "Suggestion data causing exception below is: #{suggMeta.to_xml}"
    raise
  end
end

###################################################################################################
def enhanceEmails(feedMeta, authors)
  authBefore = authors.join(";")
  (feedMeta.xpath("people/person[relationships/relationship/@type='publication-user-authorship']") +
   feedMeta.xpath("people/person[relationships/relationship/@type='publication-user-editorship']") +
   feedMeta.xpath("people/person[relationships/relationship/@type='publication-user-contributorship']") +
   feedMeta.xpath("people/person[relationships/relationship/@type='publication-user-translation']")).each { |person|
    lname = normalize(person.text_at('last-name'))
    initials = normalize(person.text_at('initials'))
    email = normalize(person.text_at('email-address'))
    if email.length > 0
      lookFor = (lname + ", " + initials + "|").downcase
      authors.map! { |auth| (auth.downcase == lookFor) ? auth + email : auth }
    end
  }
  return (authBefore != authors.join(";"))
end

###################################################################################################
def checkForMetaUpdate(pubID, ark, feedMeta, updateTime)

  print "Pub #{pubID} <=> #{ark}: "

  # See if we already have recent data for this entry.
  metaFile = arkToFile(ark, 'next/meta/base.feed.xml')
  File.file?(metaFile) or metaFile = arkToFile(ark, 'meta/base.feed.xml')
  if File.file? metaFile and File.mtime(metaFile).to_datetime > updateTime and not($onlyPub)
    puts "Already updated."
    return
  end

  # If no changes, nothing to do.
  unless isMetaChanged(ark, feedMeta)
    puts "No significant changes."
    return
  end

  # Found changes. Make a 'next' directory if necessary, and save the feed data there.
  # No clear idea who the change should be attributed to, but I see "user" in the feed
  # so let's grab that.
  puts "Changed."

  #who = feedMeta.at("//users/user[1]/email-address").try{|e| e.text.to_s}
  who = nil; puts "TODO: parse who"
  editItem(ark, who, pubID)
  File.open(arkToFile(ark, "next/meta/base.feed.xml", true), "w") { |io| feedMeta.write_xml_to io }

  # Update the UCI metadata for real.
  updateMetadata(ark)

  # If the item has been approved, push this change all the way through.
  #approveItem(ark, who) if isGranted(ark)
end

###################################################################################################
def httpGetWithRetry(http, url, user, passwd, retrySeconds = 30)
  nAttempts = 0
  nAttemptsAllowed = 30
  while true
    begin
      nAttempts += 1
      uri = URI(url)
      req = Net::HTTP::Get.new(uri)
      req.basic_auth user, passwd
      res = http.request(req)
      # THis happens all the time with Elements API: concurrency error, timeout, etc. We need to retry, a bunch of times.
      res.code == '200' or raise(res.to_s)
      return res.body
    rescue Exception => e
      if e.inspect.include?(":HTTPError: 404") || e.inspect.include?("recordItemFault")
        raise
      elsif nAttempts > nAttemptsAllowed
        raise
      elsif not e.inspect.include?("HTTP")
        raise
      end
      puts "URL open of '#{url}' failed, will retry up to #{nAttemptsAllowed-nAttempts} more times: " +
           "#{e.inspect}\n#{e.backtrace.join("\n")}"
      sleep retrySeconds
    end
  end
end


###################################################################################################
def scanPub(http, entry, user, passwd)

  # Grab the Elements publication ID
  pubID = entry.xpath("id").select{|el|el.text =~ /^\d+$/}[0].text
  pubID or raise "Error: feed entry has no id: #{entry}"

  # Figure out when it was updated
  updateTime = DateTime.iso8601(entry.at('updated').text)

  # Check that against the database
  got = $oapDb.get_first_value("SELECT updated FROM raw_items WHERE campus_id = ?", "elements::#{pubID}")
  if got && got.to_i >= updateTime.to_time.to_i && !$forceMode
    puts "Already processed pub #{pubID} (scanned=#{got.to_i} >= updated=#{updateTime.to_time.to_i})"
    return
  end

  # Detect deleted records.
  upperTitle = entry.text_at("title")
  if upperTitle.include? "object deleted" || entry.at('deleted')
    puts "deleted record: #{pubID} (updated=#{updateTime.to_time.to_i})"
    $oapDb.execute("DELETE FROM raw_items WHERE campus_id = ?", "elements::#{pubID}")
    return
  end

  puts "Processing pub #{pubID} (scanned=#{got.to_i} < updated=#{updateTime.to_time.to_i})."

  # Grab the full metadata from Elements
  if $onlyPub
    feedMeta = entry
  else
    altLink = entry.at("link[@rel='alternate']/@href").to_s
    feedMeta = nil
    feedMeta = Nokogiri::XML(httpGetWithRetry(http, altLink, user, passwd)).remove_namespaces!.root
  end

  # Figure out the ARK for this publication.
  # Note that we do *not* want to pick up ARKs for Subi, OJS, etc. Only Elements.
  ark = $arkDb.get_first_value("SELECT id FROM arks WHERE source='elements' AND external_id=?", pubID)

  # Note if merges happen, but it's better to keep going than confuse things by punting.
  detectMergeProblem(pubID, ark, feedMeta, nil)

  # Figure out the publication type
  typeName = nil
  feedMeta.xpath("category[@scheme='http://www.symplectic.co.uk/publications/atom-terms/1.0']").each { |el|
    typeName = el.attr('label') if $typeNameToID.include?(el.attr('label'))
  }
  typeName or raise("cannot find recognized typeName for feed #{feedMeta.to_xml}")

  # Parse the item into raw form for adding to the oapImport matching database
  record = getPreferredRecord(feedMeta)
  native = record.xpath(".//native") ? record.xpath(".//native")[0] : record
  rawItem = elemNativeToRawItem(native, typeName, updateTime.to_time.to_i)

  # Don't store abstracts.
  if rawItem.otherInfo
    rawItem.otherInfo.abstract = nil
    rawItem.otherInfo = (rawItem.otherInfo.select{|v| v}.empty?) ? nil : rawItem.otherInfo
  end

  # Match up any author emails we can
  emailAdded = enhanceEmails(feedMeta, rawItem.authors)

  # Add an ID referencing Elements
  rawItem.ids << ['elements', pubID]

  # Grab relationship suggestions from Elements
  rawItem.suggestions = parseSuggestions("#{$elementsAPI}/publications/#{pubID}/suggestions/relationships/pending",
                                         user, passwd)

  # Handle metadata changes (if there's an associated ark)
  ark and checkForMetaUpdate(pubID, ark, feedMeta, updateTime)

  # Add a record to the database
  #puts rawItem
  if $testMode
    puts "Skipping database add in test mode."
  else
    rawItem.save($oapDb.method(:execute))
  end
end

###################################################################################################
# Generate one entry in the feed of all publications.
def genPubEntry(xml, ark, pubID)

  # Make sure there's a metadata file.
  metaPath = arkToFile(ark, "next/meta/base.meta.xml")
  File.file? metaPath or metaPath = arkToFile(ark, "meta/base.meta.xml")
  File.exists? metaPath or return
  itemDir = getRealPath("#{metaPath}/../..")

  # Read the metadata
  io = File.open(metaPath, "r")
  meta = Nokogiri::XML(io).root
  io.close

  ############## NOTE ############
  # The following is in a special format. Not sure why this needs to be different from the normal
  # way we generate a feed response, but it does.
  # This is modeled after: http://dspace.symplectic.co.uk:8080/rt4ds/repository
  ############## NOTE ############

  # Title of the item
  xml.title meta.at("title").text if meta.at("title")

  # Categorisation marking this as a Repository Item
  xml.category scheme: "http://www.symplectic.co.uk/publications/atom-terms/1.0",
               term:   "http://www.symplectic.co.uk/publications/atom-terms/1.0/repository-item",
               label:  "Repository Item"

  # Link for editing. We don't really have that, do we? This one is invented.
  xml.link rel: "media-edit", href: "#{$server}/edit/#{pubID}"

  # Identifier of the publication (apparently, this has to be the ID within Elements)
  xml.id_ "tag:repository-tools@symplectic/publication/#{pubID}"

  # When this record was last updated
  xml.updated File.mtime(metaPath).to_datetime.iso8601

  # Link to get more data on this pub
  xml.content type: "application/atom+xml",
              src: "#{$server}/connector/publication/#{pubID}"

  # Textual description of what this entry is
  xml.summary "An entry in the repository"

  # Ian from Symplectic says we need to put the rel="alternate" link at this level
  publicURL = "#{$publicServer}/uc/item/#{getShortArk(ark).sub(/^qt/, '')}"
  if meta.attr('state') != 'withdrawn'
    xml.link rel: "alternate", href: publicURL
  end

  # Now a summary of the pub's vital info
  isFromElements = meta.at('source').text == 'oa_harvester'
  xml[:pubs].summary {

    # This ID needs to match Elements' pub ID
    xml[:pubs].id_ pubID

    # Helps Kirk identify things that are from Elements as opposed to imported from eSchol.
    # The DSpace connector uses full ISO 8601 format including the time, so let's just call
    # it midnight Pacific time shall we?
    if isFromElements
      subDate = meta.at('history/submissionDate')
      xml.send('pubs:created-date', "#{subDate.text}T00:00:00-0700") if subDate
    end

    xml.send('pubs:file-count', meta.xpath('content//file').length)
    filePath = pathFromFileMeta(ark, itemDir, meta.at('content//file[1]'))
    if isFromElements && filePath && File.exist?(filePath)
      xml.send('pubs:first-file-date', File.mtime(filePath).to_datetime.iso8601)
    end
    licensePath = findLicensePath("#{itemDir}/meta/license")
    if (licensePath && meta.attr('state') != 'withdrawn') or meta.attr('state') == 'published'
      xml.send('pubs:licence-count', 1)   # British spelling is important here
      xml.send('pubs:status', 'accepted')
      xml.send('pubs:public-url', publicURL)
    else
      xml.send('pubs:status', 'inworkspace')
    end
    if isFromElements && licensePath && File.exists?(licensePath)
      xml.send('pubs:first-licence-date', File.mtime(licensePath).to_datetime.iso8601)
    end

    # Entries for the license and content files
    xml.send('pubs:file-holdings') {
      genEntries(xml, ark, itemDir, meta, pubID)
    }
  }
end

###################################################################################################
# See if there's UCI metadata for the given ark
def isUciArk(ark)
  metaPath = arkToFile(ark, "meta/base.meta.xml")
  File.file?(metaPath) or return false
  uci = fileToXML(metaPath)
  namespaces = uci.root.namespaces
  return namespaces["xmlns:uci"] == "http://www.cdlib.org/ucingest"
end

###################################################################################################
# Form a mapping of all publications in eScholarship with corresponding Elements pubID
def getPubList

  # If there's no cached pub map, or it's more than an hour old, rebuild it.
  if !$cachedPubList || (Time.now - $cachedPubListTime) > (60*60)
    puts "Rebuilding pub map."
    map = {}

    # We have multiple sources of data for this. First is the arks database, which is where things
    # synchronously uploaded from Elements end up.
    donePubs = Set.new
    $arkDb.execute("SELECT id, external_id FROM arks WHERE source='elements'") { |row|
      ark, pubID = row
      next if donePubs.include?(pubID)
      donePubs << pubID
      ark and ark.sub!('ark:13030/', 'ark:/13030/')
      map[ark] = pubID
    }

    # Second source is the oap database, which is where we record items that pre-existed Elements
    # and have been imported by our OAP importer.
    $oapDb.execute("SELECT campus_id, pub_id FROM ids, pubs WHERE ids.oap_id = pubs.oap_id " +
                   "AND campus_id LIKE 'c-eschol-id::%'") { |row|
      ark, pubID = row
      next if donePubs.include?(pubID)
      donePubs << pubID
      ark and ark.sub!('c-eschol-id::', '')
      ark and ark.sub!('ark:13030/', 'ark:/13030/')
      map[ark] = pubID
    }

    # Third source is the eschol_equiv table (also houses in oap database), which is where we
    # items go when the user specifies an escholarship URL as the OA URL for a pub. (Also, this
    # table contains items auto-batch-imported to eSchol based on an Elements record).
    $oapDb.execute("SELECT pub_id, eschol_ark FROM eschol_equiv") { |row|
      pubID, ark = row
      next if donePubs.include?(pubID)
      donePubs << pubID
      ark =~ %r{^ark:/13030} or raise("strange ark #{ark.inspect} in eschol_equiv table")
      # Be sure to filter out Biomed, Springer, etc. -- they cause the feed page to abort with error
      if !map[ark] && isUciArk(ark)
        map[ark] = pubID
      end
    }

    $cachedPubList = map.to_a.sort
    $cachedPubListTime = Time.now
    $cachedPubListDate = DateTime.now
    puts "Pub map built."
  end

  return $cachedPubList
end

###################################################################################################
# This gets called when Elements calls us each night to get a listing of all items in the repository.
# We give them back a paged feed.
get "/connector/repository" do
  begin
    pageNum = params[:page].to_i

    # Figure out which subset of the publication list will form this page of the result set.
    pageSize = 20
    pubList = getPubList
    totalPages = (pubList.length + pageSize - 1) / pageSize
    (pageNum > 0 && pageNum <= totalPages) or halt(404)
    firstPubNum = (pageNum-1) * pageSize
    lastPubNum = [pageNum * pageSize, pubList.length].min

    # Now generate the feed for those pubs
    content_type "application/atom+xml;type=feed"
    Nokogiri::XML::Builder.new(encoding: 'UTF-8') { |xml|
      xml.feed('xmlns' => "http://www.w3.org/2005/Atom",
               'xmlns:pubs'  => "http://www.symplectic.co.uk/publications/atom-api") {
        xml.id_ "#{$server}/connector/repository"
        xml.title 'List holdings'
        xml.updated $cachedPubListDate.iso8601
        xml.author {
          xml.name 'eScholarship'
        }
        xml.category scheme: "http://www.symplectic.co.uk/publications/atom-terms/1.0",
                     term: "http://www.symplectic.co.uk/publications/atom-terms/1.0/list-holdings-response",
                     label: "List Holdings Response"

        # Navigation links
        xml.link rel: 'self', href: "#{$server}/connector/repository?page=#{pageNum}"
        if pageNum > 1
          xml.link rel: 'prev', href: "#{$server}/connector/repository?page=#{pageNum-1}"
        end
        if pageNum < totalPages
          xml.link rel: 'next', href: "#{$server}/connector/repository?page=#{pageNum+1}"
        end
        xml.link rel: 'last', href: "#{$server}/connector/repository?page=#{totalPages}"

        # Optional
        xml.subtitle 'A list of all the repository holdings which are related to Symplectic Publications'

        # Each publication gets its own entry
        (firstPubNum...lastPubNum).each { |pubNum|
          begin
            ark, pubID = pubList[pubNum]
            xml.entry {
              genPubEntry(xml, ark, pubID)
            }
          rescue
            puts "Error generating entry for pubNum=#{pubNum} ark=#{ark.inspect} pubID=#{pubID.inspect}"
            raise
          end
        }
      }
    }.to_xml
  rescue Exception => exc
    emailStaffAboutScanFailure(exc)
    raise
  end
end

###################################################################################################
get "/check" do
  "ok"  # just a little response so Monit knows we're alive
end

###################################################################################################
# When called from the command line, the program acts as a web server, or does the nightly scan of
# Elements to update linked eScholarship items.
if __FILE__ == $0
  if ARGV.include? 'serve'
    # Do nothing and allow Sinatra to take the stage
  elsif ARGV.include? 'scan'
    startPage = 1
    ARGV.length > ARGV.index('scan')+1 and startPage = ARGV[-1].to_i
    $scanMode = true
    begin
      $oapDb.busy_timeout = 240000  # be generous due to groupOaPubs running at night
      scanAllChanges(startPage)
    rescue Exception => e
      puts "Scan failed: #{e}"
      emailStaffAboutScanFailure(e)
      raise
    end
    exit 0 # Need to explicitly exit the program so Sinatra doesn't take over.
  else
    puts "Usage: #{$0} [scan {--test}] | [serve -p PORT -o ADDRESS]"
    exit 1
  end
end
