param(
  [int]$Port = 8765
)

$ErrorActionPreference = 'Stop'
$Root = Split-Path -Parent $MyInvocation.MyCommand.Path

function Send-Text {
  param(
    [System.Net.HttpListenerResponse]$Response,
    [int]$StatusCode,
    [string]$Text,
    [string]$ContentType = 'text/plain; charset=utf-8'
  )

  $bytes = [System.Text.Encoding]::UTF8.GetBytes($Text)
  $Response.StatusCode = $StatusCode
  $Response.ContentType = $ContentType
  $Response.ContentLength64 = $bytes.Length
  $Response.OutputStream.Write($bytes, 0, $bytes.Length)
}

function Read-RequestBody {
  param([System.Net.HttpListenerRequest]$Request)

  $reader = New-Object System.IO.StreamReader($Request.InputStream, $Request.ContentEncoding)
  try {
    return $reader.ReadToEnd()
  } finally {
    $reader.Dispose()
  }
}

function Get-ContentType {
  param([string]$Path)

  switch ([System.IO.Path]::GetExtension($Path).ToLowerInvariant()) {
    '.html' { return 'text/html; charset=utf-8' }
    '.css' { return 'text/css; charset=utf-8' }
    '.js' { return 'application/javascript; charset=utf-8' }
    '.ico' { return 'image/x-icon' }
    default { return 'application/octet-stream' }
  }
}

function Send-File {
  param(
    [System.Net.HttpListenerResponse]$Response,
    [string]$Path
  )

  if (-not (Test-Path -LiteralPath $Path)) {
    Send-Text $Response 404 '{"error":"文件不存在"}' 'application/json; charset=utf-8'
    return
  }

  $bytes = [System.IO.File]::ReadAllBytes($Path)
  $Response.StatusCode = 200
  $Response.ContentType = Get-ContentType $Path
  $Response.ContentLength64 = $bytes.Length
  $Response.OutputStream.Write($bytes, 0, $bytes.Length)
}

function Get-UsernameFromInput {
  param([string]$InputValue)

  $value = ($InputValue | ForEach-Object { "$_".Trim() })
  if ([string]::IsNullOrWhiteSpace($value)) {
    throw '请输入 TikTok 主页链接'
  }

  if ($value -match 'tiktok\.com/@([^/?#\s]+)') {
    return $Matches[1]
  }

  if ($value -match '^@?([A-Za-z0-9._-]+)$') {
    return $Matches[1]
  }

  throw '无法识别 TikTok 主页链接'
}

function Invoke-TikwmJson {
  param([string]$Url)

  for ($i = 1; $i -le 6; $i++) {
    try {
      $response = Invoke-WebRequest -Uri $Url -Headers @{
        'User-Agent' = 'Mozilla/5.0'
        'Accept' = 'application/json'
      } -UseBasicParsing -TimeoutSec 30
      $json = $response.Content | ConvertFrom-Json
      if ($json.code -eq 0) {
        return $json
      }
      if ([string]$json.msg -match 'Limit|request') {
        Start-Sleep -Seconds ([Math]::Min(2 * $i, 10))
        continue
      }
      return $json
    } catch {
      if ($i -eq 6) {
        throw
      }
      Start-Sleep -Seconds ([Math]::Min(2 * $i, 10))
    }
  }
}

function Clean-XmlText {
  param([object]$Value)

  if ($null -eq $Value) {
    return ''
  }

  $text = [string]$Value
  $builder = New-Object System.Text.StringBuilder
  foreach ($ch in $text.ToCharArray()) {
    $code = [int][char]$ch
    if ($code -eq 9 -or $code -eq 10 -or $code -eq 13 -or $code -ge 32) {
      [void]$builder.Append($ch)
    }
  }

  return [System.Security.SecurityElement]::Escape($builder.ToString())
}

function Get-ColumnName {
  param([int]$Number)

  $name = ''
  while ($Number -gt 0) {
    $Number--
    $name = [char](65 + ($Number % 26)) + $name
    $Number = [Math]::Floor($Number / 26)
  }
  return $name
}

function Get-CellValue {
  param($Row, [string]$Key)

  if ($Row -is [System.Collections.IDictionary]) {
    return $Row[$Key]
  }
  return $Row.PSObject.Properties[$Key].Value
}

function New-CellXml {
  param(
    [int]$RowNumber,
    [int]$ColumnNumber,
    [object]$Value,
    [bool]$IsNumber,
    [bool]$IsHeader
  )

  $ref = "$(Get-ColumnName $ColumnNumber)$RowNumber"
  $style = if ($IsHeader) { ' s="1"' } else { '' }
  if ($IsNumber) {
    if ($null -eq $Value -or $Value -eq '') {
      return "<c r=`"$ref`"$style/>"
    }
    return "<c r=`"$ref`"$style><v>$Value</v></c>"
  }

  $text = Clean-XmlText $Value
  return "<c r=`"$ref`" t=`"inlineStr`"$style><is><t xml:space=`"preserve`">$text</t></is></c>"
}

function New-SheetXml {
  param(
    [array]$Headers,
    [array]$Rows
  )

  $widths = @{
    1 = 8
    2 = 24
    3 = 24
    4 = 48
    5 = 24
    6 = 22
    7 = 64
    8 = 90
    9 = 12
    10 = 12
    11 = 12
    12 = 22
  }
  $rowCount = $Rows.Count + 1
  $lastCol = Get-ColumnName $Headers.Count
  $sheet = New-Object System.Text.StringBuilder

  [void]$sheet.Append('<?xml version="1.0" encoding="UTF-8" standalone="yes"?>')
  [void]$sheet.Append('<worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">')
  [void]$sheet.Append("<dimension ref=`"A1:$lastCol$rowCount`"/>")
  [void]$sheet.Append('<sheetViews><sheetView workbookViewId="0"><pane ySplit="1" topLeftCell="A2" activePane="bottomLeft" state="frozen"/></sheetView></sheetViews>')
  [void]$sheet.Append('<cols>')
  for ($i = 1; $i -le $Headers.Count; $i++) {
    $width = if ($widths.ContainsKey($i)) { $widths[$i] } else { 14 }
    [void]$sheet.Append("<col min=`"$i`" max=`"$i`" width=`"$width`" customWidth=`"1`"/>")
  }
  [void]$sheet.Append('</cols><sheetData>')
  [void]$sheet.Append('<row r="1">')
  for ($i = 0; $i -lt $Headers.Count; $i++) {
    [void]$sheet.Append((New-CellXml 1 ($i + 1) $Headers[$i] $false $true))
  }
  [void]$sheet.Append('</row>')

  $rowNumber = 2
  foreach ($row in $Rows) {
    [void]$sheet.Append("<row r=`"$rowNumber`">")
    for ($i = 0; $i -lt $Headers.Count; $i++) {
      $header = $Headers[$i]
      $isNumber = $header -in @('序号', '浏览量', '点赞量', '评论数')
      [void]$sheet.Append((New-CellXml $rowNumber ($i + 1) (Get-CellValue $row $header) $isNumber $false))
    }
    [void]$sheet.Append('</row>')
    $rowNumber++
  }

  [void]$sheet.Append('</sheetData>')
  [void]$sheet.Append("<autoFilter ref=`"A1:$lastCol$rowCount`"/>")
  [void]$sheet.Append('</worksheet>')
  return $sheet.ToString()
}

function Add-ZipEntry {
  param(
    [System.IO.Compression.ZipArchive]$Zip,
    [string]$Name,
    [string]$Content,
    [System.Text.Encoding]$Encoding
  )

  $entry = $Zip.CreateEntry($Name)
  $stream = $entry.Open()
  $writer = New-Object System.IO.StreamWriter($stream, $Encoding)
  try {
    $writer.Write($Content)
  } finally {
    $writer.Dispose()
    $stream.Dispose()
  }
}

function Get-SafeFileName {
  param([string]$Name, [string]$Fallback)

  $fileName = if ([string]::IsNullOrWhiteSpace($Name)) { $Fallback } else { $Name.Trim() }
  foreach ($char in [System.IO.Path]::GetInvalidFileNameChars()) {
    $fileName = $fileName.Replace([string]$char, '')
  }
  $fileName = $fileName.Trim()
  if ([string]::IsNullOrWhiteSpace($fileName)) {
    $fileName = $Fallback
  }
  if ($fileName.Length -gt 80) {
    $fileName = $fileName.Substring(0, 80).Trim()
  }
  return "$fileName.xlsx"
}

function Get-ChartRows {
  param([array]$Rows)

  return @(
    $Rows | Sort-Object {
      [DateTime]::ParseExact(
        [string](Get-CellValue $_ '发布时间(北京时间)'),
        'yyyy-MM-dd HH:mm:ss',
        [System.Globalization.CultureInfo]::InvariantCulture
      )
    }
  )
}

function New-ChartSheetXml {
  param([array]$ChartRows)

  $headers = @('视频序号', '浏览量', '点赞量', '评论数')
  $startRow = 26
  $endRow = $startRow + $ChartRows.Count
  $sheet = New-Object System.Text.StringBuilder

  [void]$sheet.Append('<?xml version="1.0" encoding="UTF-8" standalone="yes"?>')
  [void]$sheet.Append('<worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">')
  [void]$sheet.Append("<dimension ref=`"A1:D$endRow`"/>")
  [void]$sheet.Append('<sheetViews><sheetView workbookViewId="0"/></sheetViews>')
  [void]$sheet.Append('<cols><col min="1" max="1" width="12" customWidth="1"/><col min="2" max="4" width="14" customWidth="1"/></cols>')
  [void]$sheet.Append('<sheetData>')
  [void]$sheet.Append("<row r=`"$startRow`">")
  for ($i = 0; $i -lt $headers.Count; $i++) {
    [void]$sheet.Append((New-CellXml $startRow ($i + 1) $headers[$i] $false $true))
  }
  [void]$sheet.Append('</row>')

  for ($i = 0; $i -lt $ChartRows.Count; $i++) {
    $rowNumber = $startRow + $i + 1
    $row = $ChartRows[$i]
    [void]$sheet.Append("<row r=`"$rowNumber`">")
    [void]$sheet.Append((New-CellXml $rowNumber 1 ($i + 1) $true $false))
    [void]$sheet.Append((New-CellXml $rowNumber 2 ([int64](Get-CellValue $row '浏览量')) $true $false))
    [void]$sheet.Append((New-CellXml $rowNumber 3 ([int64](Get-CellValue $row '点赞量')) $true $false))
    [void]$sheet.Append((New-CellXml $rowNumber 4 ([int64](Get-CellValue $row '评论数')) $true $false))
    [void]$sheet.Append('</row>')
  }

  [void]$sheet.Append('</sheetData>')
  [void]$sheet.Append('<drawing r:id="rId1"/>')
  [void]$sheet.Append('</worksheet>')
  return $sheet.ToString()
}

function New-DrawingXml {
  return @'
<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<xdr:wsDr xmlns:xdr="http://schemas.openxmlformats.org/drawingml/2006/spreadsheetDrawing" xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main">
  <xdr:twoCellAnchor>
    <xdr:from><xdr:col>0</xdr:col><xdr:colOff>0</xdr:colOff><xdr:row>0</xdr:row><xdr:rowOff>0</xdr:rowOff></xdr:from>
    <xdr:to><xdr:col>12</xdr:col><xdr:colOff>0</xdr:colOff><xdr:row>23</xdr:row><xdr:rowOff>0</xdr:rowOff></xdr:to>
    <xdr:graphicFrame macro="">
      <xdr:nvGraphicFramePr>
        <xdr:cNvPr id="2" name="TikTok 折线统计图"/>
        <xdr:cNvGraphicFramePr/>
      </xdr:nvGraphicFramePr>
      <xdr:xfrm><a:off x="0" y="0"/><a:ext cx="0" cy="0"/></xdr:xfrm>
      <a:graphic>
        <a:graphicData uri="http://schemas.openxmlformats.org/drawingml/2006/chart">
          <c:chart xmlns:c="http://schemas.openxmlformats.org/drawingml/2006/chart" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships" r:id="rId1"/>
        </a:graphicData>
      </a:graphic>
    </xdr:graphicFrame>
    <xdr:clientData/>
  </xdr:twoCellAnchor>
</xdr:wsDr>
'@
}

function New-NumCacheXml {
  param([array]$Values)

  $cache = New-Object System.Text.StringBuilder
  [void]$cache.Append(('<c:numCache><c:formatCode>General</c:formatCode><c:ptCount val="{0}"/>' -f $Values.Count))
  for ($i = 0; $i -lt $Values.Count; $i++) {
    [void]$cache.Append(('<c:pt idx="{0}"><c:v>{1}</c:v></c:pt>' -f $i, $Values[$i]))
  }
  [void]$cache.Append('</c:numCache>')
  return $cache.ToString()
}

function New-SeriesXml {
  param(
    [int]$Index,
    [string]$Name,
    [string]$Color,
    [string]$ValueColumn,
    [array]$Categories,
    [array]$Values,
    [int]$StartRow,
    [int]$EndRow
  )

  $titleRef = "'折线图'!`$$ValueColumn`$$StartRow"
  $catRef = "'折线图'!`$A`$$(($StartRow + 1)):`$A`$$EndRow"
  $valRef = "'折线图'!`$$ValueColumn`$$(($StartRow + 1)):`$$ValueColumn`$$EndRow"
  $catCache = New-NumCacheXml $Categories
  $valCache = New-NumCacheXml $Values
  $safeName = Clean-XmlText $Name

  return @"
<c:ser>
  <c:idx val="$Index"/>
  <c:order val="$Index"/>
  <c:tx>
    <c:strRef>
      <c:f>$titleRef</c:f>
      <c:strCache><c:ptCount val="1"/><c:pt idx="0"><c:v>$safeName</c:v></c:pt></c:strCache>
    </c:strRef>
  </c:tx>
  <c:spPr>
    <a:ln w="28575"><a:solidFill><a:srgbClr val="$Color"/></a:solidFill></a:ln>
  </c:spPr>
  <c:marker>
    <c:symbol val="circle"/>
    <c:size val="5"/>
    <c:spPr><a:solidFill><a:srgbClr val="$Color"/></a:solidFill><a:ln><a:solidFill><a:srgbClr val="$Color"/></a:solidFill></a:ln></c:spPr>
  </c:marker>
  <c:dLbls>
    <c:txPr><a:bodyPr/><a:lstStyle/><a:p><a:pPr><a:defRPr sz="900"><a:solidFill><a:srgbClr val="$Color"/></a:solidFill></a:defRPr></a:pPr></a:p></c:txPr>
    <c:showLegendKey val="0"/>
    <c:showVal val="1"/>
    <c:showCatName val="0"/>
    <c:showSerName val="0"/>
    <c:showPercent val="0"/>
    <c:showBubbleSize val="0"/>
  </c:dLbls>
  <c:cat><c:numRef><c:f>$catRef</c:f>$catCache</c:numRef></c:cat>
  <c:val><c:numRef><c:f>$valRef</c:f>$valCache</c:numRef></c:val>
  <c:smooth val="0"/>
</c:ser>
"@
}

function New-ChartXml {
  param([array]$ChartRows, [string]$Title)

  $startRow = 26
  $endRow = $startRow + $ChartRows.Count
  $categories = @()
  $views = @()
  $likes = @()
  $comments = @()
  for ($i = 0; $i -lt $ChartRows.Count; $i++) {
    $row = $ChartRows[$i]
    $categories += ($i + 1)
    $views += [int64](Get-CellValue $row '浏览量')
    $likes += [int64](Get-CellValue $row '点赞量')
    $comments += [int64](Get-CellValue $row '评论数')
  }

  $safeTitle = Clean-XmlText "$Title TikTok 视频数据折线统计图"
  $viewsSeries = New-SeriesXml 0 '浏览量' 'DC2626' 'B' $categories $views $startRow $endRow
  $likesSeries = New-SeriesXml 1 '点赞量' '16A34A' 'C' $categories $likes $startRow $endRow
  $commentsSeries = New-SeriesXml 2 '评论量' '2563EB' 'D' $categories $comments $startRow $endRow

  return @"
<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<c:chartSpace xmlns:c="http://schemas.openxmlformats.org/drawingml/2006/chart" xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">
  <c:date1904 val="0"/>
  <c:lang val="zh-CN"/>
  <c:roundedCorners val="0"/>
  <c:chart>
    <c:title>
      <c:tx><c:rich><a:bodyPr/><a:lstStyle/><a:p><a:r><a:rPr lang="zh-CN" sz="1400"/><a:t>$safeTitle</a:t></a:r></a:p></c:rich></c:tx>
      <c:layout/>
      <c:overlay val="0"/>
    </c:title>
    <c:plotArea>
      <c:layout/>
      <c:lineChart>
        <c:grouping val="standard"/>
        <c:varyColors val="0"/>
        $viewsSeries
        $likesSeries
        $commentsSeries
        <c:axId val="1001"/>
        <c:axId val="1002"/>
      </c:lineChart>
      <c:catAx>
        <c:axId val="1001"/>
        <c:scaling><c:orientation val="minMax"/></c:scaling>
        <c:delete val="0"/>
        <c:axPos val="b"/>
        <c:numFmt formatCode="General" sourceLinked="1"/>
        <c:majorTickMark val="out"/>
        <c:minorTickMark val="none"/>
        <c:tickLblPos val="nextTo"/>
        <c:crossAx val="1002"/>
        <c:crosses val="autoZero"/>
        <c:auto val="1"/>
        <c:lblAlgn val="ctr"/>
        <c:lblOffset val="100"/>
      </c:catAx>
      <c:valAx>
        <c:axId val="1002"/>
        <c:scaling><c:orientation val="minMax"/></c:scaling>
        <c:delete val="0"/>
        <c:axPos val="l"/>
        <c:majorGridlines/>
        <c:numFmt formatCode="General" sourceLinked="1"/>
        <c:majorTickMark val="out"/>
        <c:minorTickMark val="none"/>
        <c:tickLblPos val="nextTo"/>
        <c:crossAx val="1001"/>
        <c:crosses val="autoZero"/>
        <c:crossBetween val="between"/>
      </c:valAx>
    </c:plotArea>
    <c:legend>
      <c:legendPos val="b"/>
      <c:layout/>
      <c:overlay val="0"/>
    </c:legend>
    <c:plotVisOnly val="1"/>
    <c:dispBlanksAs val="gap"/>
    <c:showDLblsOverMax val="0"/>
  </c:chart>
</c:chartSpace>
"@
}

function New-XlsxBytes {
  param(
    [array]$Rows,
    [string]$SheetName,
    [bool]$IncludeChart = $false
  )

  Add-Type -AssemblyName System.IO.Compression

  $headers = @('序号', '账号', '账号昵称', '账号主页', '视频ID', '发布时间(北京时间)', '视频链接', '文案', '浏览量', '点赞量', '评论数', '取数时间(北京时间)')
  $sheetXml = New-SheetXml $headers $Rows
  $chartRows = Get-ChartRows $Rows
  $chartSheetXml = if ($IncludeChart) { New-ChartSheetXml $chartRows } else { $null }
  $drawingXml = if ($IncludeChart) { New-DrawingXml } else { $null }
  $chartXml = if ($IncludeChart) { New-ChartXml $chartRows $SheetName } else { $null }
  $safeSheetName = Clean-XmlText (($SheetName -replace '[:\\/?*\[\]]', '').Trim())
  if ([string]::IsNullOrWhiteSpace($safeSheetName)) {
    $safeSheetName = '视频数据'
  }
  if ($safeSheetName.Length -gt 31) {
    $safeSheetName = $safeSheetName.Substring(0, 31)
  }

  if ($IncludeChart) {
    $contentTypes = '<?xml version="1.0" encoding="UTF-8" standalone="yes"?><Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"><Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/><Default Extension="xml" ContentType="application/xml"/><Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/><Override PartName="/xl/worksheets/sheet1.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/><Override PartName="/xl/worksheets/sheet2.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/><Override PartName="/xl/drawings/drawing1.xml" ContentType="application/vnd.openxmlformats-officedocument.drawing+xml"/><Override PartName="/xl/charts/chart1.xml" ContentType="application/vnd.openxmlformats-officedocument.drawingml.chart+xml"/><Override PartName="/xl/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.styles+xml"/><Override PartName="/docProps/core.xml" ContentType="application/vnd.openxmlformats-package.core-properties+xml"/><Override PartName="/docProps/app.xml" ContentType="application/vnd.openxmlformats-officedocument.extended-properties+xml"/></Types>'
  } else {
    $contentTypes = '<?xml version="1.0" encoding="UTF-8" standalone="yes"?><Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"><Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/><Default Extension="xml" ContentType="application/xml"/><Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/><Override PartName="/xl/worksheets/sheet1.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/><Override PartName="/xl/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.styles+xml"/><Override PartName="/docProps/core.xml" ContentType="application/vnd.openxmlformats-package.core-properties+xml"/><Override PartName="/docProps/app.xml" ContentType="application/vnd.openxmlformats-officedocument.extended-properties+xml"/></Types>'
  }
  $rels = '<?xml version="1.0" encoding="UTF-8" standalone="yes"?><Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="xl/workbook.xml"/><Relationship Id="rId2" Type="http://schemas.openxmlformats.org/package/2006/relationships/metadata/core-properties" Target="docProps/core.xml"/><Relationship Id="rId3" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/extended-properties" Target="docProps/app.xml"/></Relationships>'
  if ($IncludeChart) {
    $workbook = "<?xml version=`"1.0`" encoding=`"UTF-8`" standalone=`"yes`"?><workbook xmlns=`"http://schemas.openxmlformats.org/spreadsheetml/2006/main`" xmlns:r=`"http://schemas.openxmlformats.org/officeDocument/2006/relationships`"><sheets><sheet name=`"$safeSheetName`" sheetId=`"1`" r:id=`"rId1`"/><sheet name=`"折线图`" sheetId=`"2`" r:id=`"rId2`"/></sheets></workbook>"
    $workbookRels = '<?xml version="1.0" encoding="UTF-8" standalone="yes"?><Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet1.xml"/><Relationship Id="rId2" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet2.xml"/><Relationship Id="rId3" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles" Target="styles.xml"/></Relationships>'
  } else {
    $workbook = "<?xml version=`"1.0`" encoding=`"UTF-8`" standalone=`"yes`"?><workbook xmlns=`"http://schemas.openxmlformats.org/spreadsheetml/2006/main`" xmlns:r=`"http://schemas.openxmlformats.org/officeDocument/2006/relationships`"><sheets><sheet name=`"$safeSheetName`" sheetId=`"1`" r:id=`"rId1`"/></sheets></workbook>"
    $workbookRels = '<?xml version="1.0" encoding="UTF-8" standalone="yes"?><Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet1.xml"/><Relationship Id="rId2" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles" Target="styles.xml"/></Relationships>'
  }
  $styles = '<?xml version="1.0" encoding="UTF-8" standalone="yes"?><styleSheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"><fonts count="2"><font><sz val="11"/><name val="Calibri"/></font><font><b/><sz val="11"/><name val="Calibri"/></font></fonts><fills count="3"><fill><patternFill patternType="none"/></fill><fill><patternFill patternType="gray125"/></fill><fill><patternFill patternType="solid"><fgColor rgb="FFEFEFEF"/><bgColor indexed="64"/></patternFill></fill></fills><borders count="1"><border><left/><right/><top/><bottom/><diagonal/></border></borders><cellStyleXfs count="1"><xf numFmtId="0" fontId="0" fillId="0" borderId="0"/></cellStyleXfs><cellXfs count="2"><xf numFmtId="0" fontId="0" fillId="0" borderId="0" xfId="0"/><xf numFmtId="0" fontId="1" fillId="2" borderId="0" xfId="0" applyFont="1" applyFill="1"/></cellXfs><cellStyles count="1"><cellStyle name="Normal" xfId="0" builtinId="0"/></cellStyles></styleSheet>'
  $now = [DateTimeOffset]::Now.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
  $core = "<?xml version=`"1.0`" encoding=`"UTF-8`" standalone=`"yes`"?><cp:coreProperties xmlns:cp=`"http://schemas.openxmlformats.org/package/2006/metadata/core-properties`" xmlns:dc=`"http://purl.org/dc/elements/1.1/`" xmlns:dcterms=`"http://purl.org/dc/terms/`" xmlns:dcmitype=`"http://purl.org/dc/dcmitype/`" xmlns:xsi=`"http://www.w3.org/2001/XMLSchema-instance`"><dc:title>TikTok视频数据</dc:title><dc:creator>Codex</dc:creator><cp:lastModifiedBy>Codex</cp:lastModifiedBy><dcterms:created xsi:type=`"dcterms:W3CDTF`">$now</dcterms:created><dcterms:modified xsi:type=`"dcterms:W3CDTF`">$now</dcterms:modified></cp:coreProperties>"
  $app = '<?xml version="1.0" encoding="UTF-8" standalone="yes"?><Properties xmlns="http://schemas.openxmlformats.org/officeDocument/2006/extended-properties" xmlns:vt="http://schemas.openxmlformats.org/officeDocument/2006/docPropsVTypes"><Application>Codex</Application></Properties>'

  $encoding = New-Object System.Text.UTF8Encoding $false
  $memoryStream = New-Object System.IO.MemoryStream
  $zip = New-Object System.IO.Compression.ZipArchive($memoryStream, [System.IO.Compression.ZipArchiveMode]::Create, $true)
  try {
    Add-ZipEntry $zip '[Content_Types].xml' $contentTypes $encoding
    Add-ZipEntry $zip '_rels/.rels' $rels $encoding
    Add-ZipEntry $zip 'xl/workbook.xml' $workbook $encoding
    Add-ZipEntry $zip 'xl/_rels/workbook.xml.rels' $workbookRels $encoding
    Add-ZipEntry $zip 'xl/worksheets/sheet1.xml' $sheetXml $encoding
    if ($IncludeChart) {
      Add-ZipEntry $zip 'xl/worksheets/sheet2.xml' $chartSheetXml $encoding
      Add-ZipEntry $zip 'xl/worksheets/_rels/sheet2.xml.rels' '<?xml version="1.0" encoding="UTF-8" standalone="yes"?><Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/drawing" Target="../drawings/drawing1.xml"/></Relationships>' $encoding
      Add-ZipEntry $zip 'xl/drawings/drawing1.xml' $drawingXml $encoding
      Add-ZipEntry $zip 'xl/drawings/_rels/drawing1.xml.rels' '<?xml version="1.0" encoding="UTF-8" standalone="yes"?><Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/chart" Target="../charts/chart1.xml"/></Relationships>' $encoding
      Add-ZipEntry $zip 'xl/charts/chart1.xml' $chartXml $encoding
    }
    Add-ZipEntry $zip 'xl/styles.xml' $styles $encoding
    Add-ZipEntry $zip 'docProps/core.xml' $core $encoding
    Add-ZipEntry $zip 'docProps/app.xml' $app $encoding
  } finally {
    $zip.Dispose()
  }

  $bytes = $memoryStream.ToArray()
  $memoryStream.Dispose()
  return $bytes
}

function New-ChartSvgText {
  param(
    [array]$Rows,
    [string]$Title
  )

  $width = 1120
  $height = 680
  $left = 86
  $right = 42
  $top = 92
  $bottom = 108
  $plotWidth = $width - $left - $right
  $plotHeight = $height - $top - $bottom
  $ChartRows = @(
    $Rows | Sort-Object {
      [DateTime]::ParseExact(
        [string](Get-CellValue $_ '发布时间(北京时间)'),
        'yyyy-MM-dd HH:mm:ss',
        [System.Globalization.CultureInfo]::InvariantCulture
      )
    }
  )
  $count = $ChartRows.Count

  $maxValue = 1
  foreach ($row in $ChartRows) {
    $views = [double](Get-CellValue $row '浏览量')
    $likes = [double](Get-CellValue $row '点赞量')
    $comments = [double](Get-CellValue $row '评论数')
    $maxValue = [Math]::Max($maxValue, [Math]::Max($views, [Math]::Max($likes, $comments)))
  }
  $maxValue = [Math]::Ceiling($maxValue * 1.08)
  if ($maxValue -lt 1) {
    $maxValue = 1
  }

  function Get-X {
    param([int]$Index)
    if ($count -le 1) {
      return $left + ($plotWidth / 2)
    }
    return $left + (($Index / ($count - 1)) * $plotWidth)
  }

  function Get-Y {
    param([double]$Value)
    return $top + ((1 - ($Value / $maxValue)) * $plotHeight)
  }

  function Get-PolylinePoints {
    param([string]$Metric)
    $points = New-Object System.Collections.Generic.List[string]
    for ($i = 0; $i -lt $ChartRows.Count; $i++) {
      $row = $ChartRows[$i]
      $x = Get-X $i
      $y = Get-Y ([double](Get-CellValue $row $Metric))
      $points.Add(('{0},{1}' -f ([Math]::Round($x, 2)), ([Math]::Round($y, 2)))) | Out-Null
    }
    return ($points -join ' ')
  }

  function New-PointCircles {
    param([string]$Metric, [string]$Color)
    $circles = New-Object System.Text.StringBuilder
    for ($i = 0; $i -lt $ChartRows.Count; $i++) {
      $row = $ChartRows[$i]
      $x = Get-X $i
      $y = Get-Y ([double](Get-CellValue $row $Metric))
      [void]$circles.Append(('<circle cx="{0}" cy="{1}" r="3.6" fill="{2}"/>' -f ([Math]::Round($x, 2)), ([Math]::Round($y, 2)), $Color))
    }
    return $circles.ToString()
  }

  function New-PointLabels {
    param([string]$Metric, [string]$Color, [double]$OffsetY)
    $labels = New-Object System.Text.StringBuilder
    for ($i = 0; $i -lt $ChartRows.Count; $i++) {
      $row = $ChartRows[$i]
      $x = Get-X $i
      $value = [double](Get-CellValue $row $Metric)
      $y = (Get-Y $value) + $OffsetY
      $y = [Math]::Max(($top + 12), [Math]::Min(($height - $bottom - 6), $y))
      [void]$labels.Append(('<text x="{0}" y="{1}" text-anchor="middle" font-size="10" font-weight="600" fill="{2}">{3}</text>' -f ([Math]::Round($x, 2)), ([Math]::Round($y, 2)), $Color, ([Math]::Round($value))))
    }
    return $labels.ToString()
  }

  $titleText = Clean-XmlText "$Title TikTok 视频数据折线统计图"
  $subtitle = Clean-XmlText "横轴为单个视频，按发布时间从最早到最新排序；纵轴为数量"
  $viewsPoints = Get-PolylinePoints '浏览量'
  $likesPoints = Get-PolylinePoints '点赞量'
  $commentsPoints = Get-PolylinePoints '评论数'
  $grid = New-Object System.Text.StringBuilder
  for ($i = 0; $i -le 5; $i++) {
    $value = ($maxValue / 5) * $i
    $y = Get-Y $value
    $label = [Math]::Round($value)
    [void]$grid.Append(('<line x1="{0}" y1="{1}" x2="{2}" y2="{1}" stroke="#e5e7eb" stroke-width="1"/>' -f $left, ([Math]::Round($y, 2)), ($width - $right)))
    [void]$grid.Append(('<text x="{0}" y="{1}" text-anchor="end" font-size="12" fill="#667085">{2}</text>' -f ($left - 12), ([Math]::Round($y + 4, 2)), $label))
  }

  $xLabels = New-Object System.Text.StringBuilder
  $step = [Math]::Max(1, [Math]::Ceiling($count / 12))
  for ($i = 0; $i -lt $count; $i++) {
    if ($i % $step -ne 0 -and $i -ne ($count - 1)) {
      continue
    }
    $x = Get-X $i
    $label = [string]($i + 1)
    [void]$xLabels.Append(('<text x="{0}" y="{1}" text-anchor="middle" font-size="12" fill="#667085">{2}</text>' -f ([Math]::Round($x, 2)), ($height - 70), (Clean-XmlText $label)))
  }

  $viewsCircles = New-PointCircles '浏览量' '#dc2626'
  $likesCircles = New-PointCircles '点赞量' '#16a34a'
  $commentsCircles = New-PointCircles '评论数' '#2563eb'
  $viewsLabels = New-PointLabels '浏览量' '#dc2626' -10
  $likesLabels = New-PointLabels '点赞量' '#16a34a' 16
  $commentsLabels = New-PointLabels '评论数' '#2563eb' 30
  $plotBottom = $height - $bottom
  $plotRight = $width - $right

  return @"
<?xml version="1.0" encoding="UTF-8"?>
<svg xmlns="http://www.w3.org/2000/svg" width="$width" height="$height" viewBox="0 0 $width $height">
  <rect width="100%" height="100%" fill="#ffffff"/>
  <text x="$left" y="42" font-size="28" font-family="Segoe UI, Microsoft YaHei, Arial, sans-serif" font-weight="700" fill="#111827">$titleText</text>
  <text x="$left" y="68" font-size="14" font-family="Segoe UI, Microsoft YaHei, Arial, sans-serif" fill="#667085">$subtitle</text>
  <g font-family="Segoe UI, Microsoft YaHei, Arial, sans-serif">
    $grid
    <line x1="$left" y1="$top" x2="$left" y2="$plotBottom" stroke="#98a2b3" stroke-width="1.3"/>
    <line x1="$left" y1="$plotBottom" x2="$plotRight" y2="$plotBottom" stroke="#98a2b3" stroke-width="1.3"/>
    $xLabels
    <text x="$plotRight" y="$($height - 34)" text-anchor="end" font-size="13" fill="#667085">视频序号</text>

    <polyline points="$viewsPoints" fill="none" stroke="#dc2626" stroke-width="3" stroke-linejoin="round" stroke-linecap="round"/>
    <polyline points="$likesPoints" fill="none" stroke="#16a34a" stroke-width="3" stroke-linejoin="round" stroke-linecap="round"/>
    <polyline points="$commentsPoints" fill="none" stroke="#2563eb" stroke-width="3" stroke-linejoin="round" stroke-linecap="round"/>
    $viewsCircles
    $likesCircles
    $commentsCircles
    $viewsLabels
    $likesLabels
    $commentsLabels

    <g transform="translate($left,$($height - 34))" font-size="14" fill="#344054">
      <rect x="0" y="-12" width="18" height="4" fill="#dc2626"/>
      <text x="26" y="-6">红色：浏览量</text>
      <rect x="146" y="-12" width="18" height="4" fill="#16a34a"/>
      <text x="172" y="-6">绿色：点赞量</text>
      <rect x="292" y="-12" width="18" height="4" fill="#2563eb"/>
      <text x="318" y="-6">蓝色：评论量</text>
    </g>
  </g>
</svg>
"@
}

function Send-FilesJson {
  param(
    [System.Net.HttpListenerResponse]$Response,
    [array]$Files,
    [object]$Meta
  )

  $payload = @{
    meta = @{
      requestedCount = $Meta.RequestedCount
      profileVideoCount = $Meta.ProfileVideoCount
      extractedCount = $Meta.ExtractedCount
      nickname = $Meta.Nickname
      username = $Meta.Username
    }
    files = $Files
  }
  $json = $payload | ConvertTo-Json -Depth 8 -Compress
  $Response.Headers.Add('X-Extracted-Count', [string]$Meta.ExtractedCount)
  $Response.Headers.Add('X-Profile-Video-Count', [string]$Meta.ProfileVideoCount)
  $Response.Headers.Add('X-Requested-Count', [string]$Meta.RequestedCount)
  Send-Text $Response 200 $json 'application/json; charset=utf-8'
}

function Get-ProfileVideoRows {
  param(
    [string]$ProfileInput,
    [int]$RequestedCount
  )

  if ($RequestedCount -lt 1) {
    throw '提取数量必须大于 0'
  }

  $username = Get-UsernameFromInput $ProfileInput
  $encodedUsername = [System.Uri]::EscapeDataString($username)

  $info = Invoke-TikwmJson "https://tikwm.com/api/user/info?unique_id=$encodedUsername"
  if ($null -eq $info -or $info.code -ne 0) {
    $message = if ($info.msg) { $info.msg } else { '无法读取账号信息' }
    throw $message
  }

  $nickname = [string]$info.data.user.nickname
  $profileVideoCount = [int]$info.data.stats.videoCount
  $targetCount = [Math]::Min($RequestedCount, $profileVideoCount)
  $snapshot = [DateTimeOffset]::Now.ToOffset([TimeSpan]::FromHours(8)).ToString('yyyy-MM-dd HH:mm:ss')
  $all = @()
  $cursor = '0'
  $page = 0

  while ($all.Count -lt $targetCount -and $page -lt 50) {
    $page++
    Start-Sleep -Milliseconds 1200
    $posts = Invoke-TikwmJson "https://tikwm.com/api/user/posts?unique_id=$encodedUsername&count=30&cursor=$cursor"
    if ($null -eq $posts -or $posts.code -ne 0) {
      $message = if ($posts.msg) { $posts.msg } else { '无法读取视频列表' }
      throw $message
    }

    $all += @($posts.data.videos)
    $cursor = [string]$posts.data.cursor
    $hasMore = [bool]$posts.data.hasMore
    if (-not $hasMore) {
      break
    }
  }

  $videos = @($all | Sort-Object video_id -Unique | Sort-Object create_time -Descending | Select-Object -First $targetCount)
  $rows = New-Object System.Collections.Generic.List[object]
  $index = 1
  foreach ($video in $videos) {
    $created = [DateTimeOffset]::FromUnixTimeSeconds([int64]$video.create_time).ToOffset([TimeSpan]::FromHours(8)).ToString('yyyy-MM-dd HH:mm:ss')
    $rows.Add([ordered]@{
      '序号' = $index
      '账号' = '@' + $username
      '账号昵称' = $nickname
      '账号主页' = "https://www.tiktok.com/@$username"
      '视频ID' = [string]$video.video_id
      '发布时间(北京时间)' = $created
      '视频链接' = "https://www.tiktok.com/@$username/video/$($video.video_id)"
      '文案' = ([string]$video.title).Trim()
      '浏览量' = [int64]$video.play_count
      '点赞量' = [int64]$video.digg_count
      '评论数' = [int64]$video.comment_count
      '取数时间(北京时间)' = $snapshot
    }) | Out-Null
    $index++
  }

  return [pscustomobject]@{
    Username = $username
    Nickname = $nickname
    RequestedCount = $RequestedCount
    ProfileVideoCount = $profileVideoCount
    ExtractedCount = $videos.Count
    Rows = [object[]]$rows.ToArray()
  }
}

function Send-Workbook {
  param(
    [System.Net.HttpListenerResponse]$Response,
    [byte[]]$Bytes,
    [string]$FileName,
    [object]$Meta
  )

  $encodedName = [System.Uri]::EscapeDataString($FileName)
  $fallback = 'tiktok-data.xlsx'
  $Response.StatusCode = 200
  $Response.ContentType = 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet'
  $Response.ContentLength64 = $Bytes.Length
  $Response.Headers.Add('Content-Disposition', "attachment; filename=`"$fallback`"; filename*=UTF-8''$encodedName")
  $Response.Headers.Add('X-Extracted-Count', [string]$Meta.ExtractedCount)
  $Response.Headers.Add('X-Profile-Video-Count', [string]$Meta.ProfileVideoCount)
  $Response.Headers.Add('X-Requested-Count', [string]$Meta.RequestedCount)
  $Response.OutputStream.Write($Bytes, 0, $Bytes.Length)
}

$listener = New-Object System.Net.HttpListener
$listener.Prefixes.Add("http://localhost:$Port/")
$listener.Start()

Write-Host "TikTok 视频数据工具已启动：http://localhost:$Port/"
Write-Host '按 Ctrl+C 停止服务。'

try {
  while ($listener.IsListening) {
    $context = $listener.GetContext()
    $request = $context.Request
    $response = $context.Response
    try {
      $path = $request.Url.AbsolutePath
      if ($request.HttpMethod -eq 'GET' -and ($path -eq '/' -or $path -eq '/index.html')) {
        Send-File $response (Join-Path $Root 'index.html')
      } elseif ($request.HttpMethod -eq 'GET' -and $path -eq '/styles.css') {
        Send-File $response (Join-Path $Root 'styles.css')
      } elseif ($request.HttpMethod -eq 'GET' -and $path -eq '/app.js') {
        Send-File $response (Join-Path $Root 'app.js')
      } elseif ($request.HttpMethod -eq 'POST' -and $path -eq '/api/extract') {
        $body = Read-RequestBody $request
        $payload = $body | ConvertFrom-Json
        $count = [int]$payload.count
        $generateChart = [bool]$payload.generateChart
        $result = Get-ProfileVideoRows $payload.profileUrl $count
        $fileName = Get-SafeFileName $result.Nickname $result.Username
        $bytes = New-XlsxBytes $result.Rows $result.Nickname $generateChart
        Send-Workbook $response $bytes $fileName $result
      } else {
        Send-Text $response 404 '{"error":"未找到页面"}' 'application/json; charset=utf-8'
      }
    } catch {
      $message = $_.Exception.Message
      $json = @{ error = $message } | ConvertTo-Json -Compress
      Send-Text $response 500 $json 'application/json; charset=utf-8'
    } finally {
      $response.OutputStream.Close()
    }
  }
} finally {
  if ($listener.IsListening) {
    $listener.Stop()
  }
  $listener.Close()
}





