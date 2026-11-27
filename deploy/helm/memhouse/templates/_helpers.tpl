{{/* SPDX-License-Identifier: Apache-2.0 */}}
{{- define "memhouse.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{- define "memhouse.fullname" -}}
{{- if .Values.fullnameOverride }}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- $name := default .Chart.Name .Values.nameOverride }}
{{- if contains $name .Release.Name }}
{{- .Release.Name | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- printf "%s-%s" .Release.Name $name | trunc 63 | trimSuffix "-" }}
{{- end }}
{{- end }}
{{- end }}

{{- define "memhouse.labels" -}}
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{ include "memhouse.selectorLabels" . }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{- define "memhouse.selectorLabels" -}}
app.kubernetes.io/name: {{ include "memhouse.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{- define "memhouse.serviceAccountName" -}}
{{- if .Values.serviceAccount.create }}
{{- default (include "memhouse.fullname" .) .Values.serviceAccount.name }}
{{- else }}
{{- default "default" .Values.serviceAccount.name }}
{{- end }}
{{- end }}

{{/* The image reference: a digest, when given, over the tag. */}}
{{- define "memhouse.image" -}}
{{- if .Values.image.digest }}
{{- printf "%s@%s" .Values.image.repository .Values.image.digest }}
{{- else }}
{{- printf "%s:%s" .Values.image.repository (default .Chart.AppVersion .Values.image.tag) }}
{{- end }}
{{- end }}

{{/*
Whole numbers back to integers, in place, through maps and lists. Helm reads every number of
a values file as a float, and the TOML encoder would write `max_connections = 32.0`, which
MemHouse refuses for an integer setting. A whole number written for a fractional setting
(`sample_ratio: 1`) is read by MemHouse as that fraction.
*/}}
{{- define "memhouse.wholeNumbers" -}}
{{- $map := . -}}
{{- range $key, $value := $map -}}
{{- if kindIs "map" $value -}}
{{- $_ := include "memhouse.wholeNumbers" $value -}}
{{- else if kindIs "slice" $value -}}
{{- $items := list -}}
{{- range $value -}}
{{- if kindIs "map" . -}}
{{- $_ := include "memhouse.wholeNumbers" . -}}
{{- $items = append $items . -}}
{{- else if and (kindIs "float64" .) (eq (floor .) .) -}}
{{- $items = append $items (int64 .) -}}
{{- else -}}
{{- $items = append $items . -}}
{{- end -}}
{{- end -}}
{{- $_ := set $map $key $items -}}
{{- else if and (kindIs "float64" $value) (eq (floor $value) $value) -}}
{{- $_ := set $map $key (int64 $value) -}}
{{- end -}}
{{- end -}}
{{- end }}

{{/* The configuration file: the values' map, with the keys the chart owns set over it. */}}
{{- define "memhouse.config" -}}
{{- $server := dict "bind" "0.0.0.0:7077" }}
{{- if .Values.console.publicUrl }}
{{- $_ := set $server "public_url" .Values.console.publicUrl }}
{{- end }}
{{- $config := deepCopy .Values.config }}
{{- $_ := set $config "server" (mergeOverwrite (default (dict) (get $config "server")) $server) }}
{{- $_ := include "memhouse.wholeNumbers" $config }}
{{- toToml $config }}
{{- end }}
