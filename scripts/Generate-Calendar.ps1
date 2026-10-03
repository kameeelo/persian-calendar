#Requires -Version 7.0
[CmdletBinding()]
param(
    [ValidateRange(1300, 1500)][int]$StartYear = 1405,
    [ValidateRange(1300, 1500)][int]$EndYear = 1409,
    [ValidateSet('Persian', 'Latin')][string]$Digits = 'Persian',
    [ValidateSet('Compact', 'Full')][string]$TitleStyle = 'Compact',
    [string]$OutputDirectory = (Join-Path $PSScriptRoot '../feeds'),
    [ValidatePattern('^[0-9]{8}T[0-9]{6}Z$')][string]$RevisionStamp = '20261003T000000Z'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if ($EndYear -lt $StartYear) { throw 'EndYear must be greater than or equal to StartYear.' }
[void][datetime]::ParseExact($RevisionStamp, "yyyyMMdd'T'HHmmss'Z'", [cultureinfo]::InvariantCulture)

$calendar = [System.Globalization.PersianCalendar]::new()
$utf8 = [System.Text.UTF8Encoding]::new($false, $true)
$months = @('فروردین', 'اردیبهشت', 'خرداد', 'تیر', 'مرداد', 'شهریور', 'مهر', 'آبان', 'آذر', 'دی', 'بهمن', 'اسفند')
$weekdays = @('یکشنبه', 'دوشنبه', 'سه‌شنبه', 'چهارشنبه', 'پنجشنبه', 'جمعه', 'شنبه')

function Format-Digits([string]$Value) {
    if ($Digits -eq 'Latin') { return $Value }
    for ($number = 0; $number -le 9; $number++) {
        $Value = $Value.Replace([char](48 + $number), [char](1776 + $number))
    }
    return $Value
}

function Escape-CalendarText([string]$Value) {
    return $Value.Replace('\', '\\').Replace("`r`n", '\n').Replace("`n", '\n').Replace("`r", '\n').Replace(';', '\;').Replace(',', '\,')
}

function Fold-CalendarLine([string]$Line) {
    # RFC 5545 counts UTF-8 octets, including the continuation space.
    $builder = [System.Text.StringBuilder]::new()
    $octets = 0
    foreach ($rune in $Line.EnumerateRunes()) {
        $part = $rune.ToString()
        $length = $utf8.GetByteCount($part)
        if ($octets + $length -gt 75) {
            [void]$builder.Append("`r`n ")
            $octets = 1
        }
        [void]$builder.Append($part)
        $octets += $length
    }
    return $builder.ToString()
}

$lines = [System.Collections.Generic.List[string]]::new()
@(
    'BEGIN:VCALENDAR',
    'VERSION:2.0',
    'PRODID:-//Independent Persian Calendar//Daily Dates 1.0//FA',
    'CALSCALE:GREGORIAN',
    'METHOD:PUBLISH',
    ('X-WR-CALNAME:' + (Escape-CalendarText 'تاریخ شمسی')),
    ('X-WR-CALDESC:' + (Escape-CalendarText (Format-Digits "تاریخ روزانهٔ شمسی، $StartYear تا $EndYear؛ بدون هشدار و پیوند")))
) | ForEach-Object { $lines.Add($_) }

$firstDate = $calendar.ToDateTime($StartYear, 1, 1, 0, 0, 0, 0)
$endExclusive = $calendar.ToDateTime($EndYear + 1, 1, 1, 0, 0, 0, 0)
$eventCount = 0
for ($date = $firstDate; $date -lt $endExclusive; $date = $date.AddDays(1)) {
    $year = $calendar.GetYear($date)
    $month = $calendar.GetMonth($date)
    $day = $calendar.GetDayOfMonth($date)
    $title = "$($weekdays[[int]$date.DayOfWeek])، $day $($months[$month - 1])"
    if ($TitleStyle -eq 'Full') { $title += " $year" }
    $title = Format-Digits $title
    $solarDate = Format-Digits ('{0:0000}/{1:00}/{2:00}' -f $year, $month, $day)
    $gregorianDate = $date.ToString('yyyy-MM-dd', [cultureinfo]::InvariantCulture)
    $description = "شمسی: $solarDate`nمیلادی: $gregorianDate"
    $idDate = $date.ToString('yyyyMMdd', [cultureinfo]::InvariantCulture)
    @(
        'BEGIN:VEVENT',
        "UID:persian-date-$idDate@independent-persian-calendar",
        "DTSTAMP:$RevisionStamp",
        "DTSTART;VALUE=DATE:$idDate",
        ('DTEND;VALUE=DATE:' + $date.AddDays(1).ToString('yyyyMMdd', [cultureinfo]::InvariantCulture)),
        ('SUMMARY:' + (Escape-CalendarText $title)),
        ('DESCRIPTION:' + (Escape-CalendarText $description)),
        'TRANSP:TRANSPARENT',
        'END:VEVENT'
    ) | ForEach-Object { $lines.Add($_) }
    $eventCount++
}
$lines.Add('END:VCALENDAR')
$content = (($lines | ForEach-Object { Fold-CalendarLine $_ }) -join "`r`n") + "`r`n"

# Closed list: a future edit cannot silently introduce alarms, URLs, or attachments.
$allowed = @('BEGIN', 'END', 'VERSION', 'PRODID', 'CALSCALE', 'METHOD', 'X-WR-CALNAME', 'X-WR-CALDESC', 'UID', 'DTSTAMP', 'DTSTART', 'DTEND', 'SUMMARY', 'DESCRIPTION', 'TRANSP')
foreach ($line in $lines) {
    $property = ($line -split '[:;]', 2)[0]
    if ($property -notin $allowed) { throw "Unexpected calendar property: $property" }
}
if ($content -match '(?i)(https?://|webcal:|mailto:|javascript:|<script|<iframe|<img)') {
    throw 'Links or active markup are not allowed in this feed.'
}

[void][System.IO.Directory]::CreateDirectory([System.IO.Path]::GetFullPath($OutputDirectory))
$outputPath = [System.IO.Path]::GetFullPath((Join-Path $OutputDirectory 'persian-dates.ics'))
[System.IO.File]::WriteAllText($outputPath, $content, $utf8)
[pscustomobject]@{
    Path = $outputPath
    Events = $eventCount
    FirstDate = $firstDate.ToString('yyyy-MM-dd')
    LastDate = $endExclusive.AddDays(-1).ToString('yyyy-MM-dd')
    SHA256 = (Get-FileHash -LiteralPath $outputPath -Algorithm SHA256).Hash.ToLowerInvariant()
}

function Write-OccasionFeed([string]$Filename, [string]$Name, [string]$Coverage, [string]$Kind, [array]$Occasions) {
    $feedLines = [System.Collections.Generic.List[string]]::new()
    @('BEGIN:VCALENDAR', 'VERSION:2.0', 'PRODID:-//Independent Persian Calendar//Occasions 1.0//FA',
      'CALSCALE:GREGORIAN', 'METHOD:PUBLISH', ('X-WR-CALNAME:' + (Escape-CalendarText $Name)),
      ('X-WR-CALDESC:' + (Escape-CalendarText $Coverage))) | ForEach-Object { $feedLines.Add($_) }
    $identifiers = [System.Collections.Generic.HashSet[string]]::new()
    foreach ($occasion in ($Occasions | Sort-Object year, month, day)) {
        $occasionDate = $calendar.ToDateTime($occasion.year, $occasion.month, $occasion.day, 0, 0, 0, 0)
        $solar = '{0:0000}/{1:00}/{2:00}' -f $occasion.year, $occasion.month, $occasion.day
        $uid = '{0}-{1:0000}{2:00}{3:00}@independent-persian-calendar' -f $Kind, $occasion.year, $occasion.month, $occasion.day
        if (-not $identifiers.Add($uid)) { throw "Duplicate occasion date: $solar" }
        $details = "شمسی: $(Format-Digits $solar)`nمیلادی: $($occasionDate.ToString('yyyy-MM-dd', [cultureinfo]::InvariantCulture))`n$Coverage"
        @('BEGIN:VEVENT', "UID:$uid", "DTSTAMP:$RevisionStamp",
          ('DTSTART;VALUE=DATE:' + $occasionDate.ToString('yyyyMMdd', [cultureinfo]::InvariantCulture)),
          ('DTEND;VALUE=DATE:' + $occasionDate.AddDays(1).ToString('yyyyMMdd', [cultureinfo]::InvariantCulture)),
          ('SUMMARY:' + (Escape-CalendarText $occasion.title)),
          ('DESCRIPTION:' + (Escape-CalendarText $details)), 'TRANSP:TRANSPARENT', 'END:VEVENT'
        ) | ForEach-Object { $feedLines.Add($_) }
    }
    $feedLines.Add('END:VCALENDAR')
    foreach ($feedLine in $feedLines) {
        if (($feedLine -split '[:;]', 2)[0] -notin $allowed) { throw 'Unexpected property in occasion feed.' }
        if ($feedLine -match '[\r\n]') { throw 'Unescaped line break in occasion feed.' }
    }
    $feedContent = (($feedLines | ForEach-Object { Fold-CalendarLine $_ }) -join "`r`n") + "`r`n"
    if ($feedContent -match '(?i)(https?://|webcal:|mailto:|javascript:|data:|file:|<script|<iframe|<img)') {
        throw 'Links or active markup are not allowed in occasion feeds.'
    }
    $feedPath = [System.IO.Path]::GetFullPath((Join-Path $OutputDirectory $Filename))
    [System.IO.File]::WriteAllText($feedPath, $feedContent, $utf8)
    [pscustomobject]@{ Path=$feedPath; Events=$Occasions.Count; SHA256=(Get-FileHash -LiteralPath $feedPath -Algorithm SHA256).Hash.ToLowerInvariant() }
}

$dataDirectory = Join-Path $PSScriptRoot '../data'
$holidayDataset = Get-Content -LiteralPath (Join-Path $dataDirectory 'holidays-1405.json') -Raw -Encoding utf8 | ConvertFrom-Json
if ($holidayDataset.year -ge $StartYear -and $holidayDataset.year -le $EndYear) {
    $holidayEvents = @($holidayDataset.events | ForEach-Object {
        [pscustomobject]@{year=[int]$holidayDataset.year;month=[int]$_.month;day=[int]$_.day;title="تعطیل: $($_.title)"}
    })
    Write-OccasionFeed 'iran-holidays.ics' 'تعطیلات ایران — ۱۴۰۵' 'تعطیلات تقویم منتشرشدهٔ ۱۴۰۵؛ بدون جمعه‌های عادی و تعطیلی‌های موردی. سال‌های بعد هنوز اضافه نشده‌اند.' 'iran-holiday' $holidayEvents
} else {
    Write-Warning 'The requested date range has no verified holiday dataset. iran-holidays.ics was not modified.'
}

$culturalDataset = Get-Content -LiteralPath (Join-Path $dataDirectory 'cultural.json') -Raw -Encoding utf8 | ConvertFrom-Json
$culturalEvents = @(foreach ($culturalYear in $StartYear..$EndYear) {
    foreach ($occasion in $culturalDataset.events) {
        [pscustomobject]@{year=$culturalYear;month=[int]$occasion.month;day=[int]$occasion.day;title=$occasion.title}
    }
})
Write-OccasionFeed 'iran-culture.ics' 'مناسبت‌های فرهنگی ایران' 'گزیدهٔ مناسبت‌های فرهنگی با تاریخ ثابت شمسی؛ تکرار بر مبنای تقویم ۱۴۰۵. این عنوان به‌تنهایی به معنی تعطیلی نیست.' 'iran-culture' $culturalEvents
