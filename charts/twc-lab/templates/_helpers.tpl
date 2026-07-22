{{- define "twc-lab.name" -}}
{{- .Chart.Name | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "twc-lab.rawFullname" -}}
{{- if .Values.fullnameOverride -}}
{{- .Values.fullnameOverride -}}
{{- else if contains .Chart.Name .Release.Name -}}
{{- .Release.Name -}}
{{- else -}}
{{- printf "%s-%s" .Release.Name .Chart.Name -}}
{{- end -}}
{{- end -}}

{{- define "twc-lab.fullname" -}}
{{- $raw := include "twc-lab.rawFullname" . -}}
{{- if gt (len $raw) 63 -}}
{{- printf "%s-%s" ($raw | trunc 54 | trimSuffix "-") ($raw | sha256sum | trunc 8) -}}
{{- else -}}
{{- $raw | trimSuffix "-" -}}
{{- end -}}
{{- end -}}

{{- define "twc-lab.componentName" -}}
{{- $rawBase := include "twc-lab.rawFullname" .root -}}
{{- $candidate := printf "%s-%s" $rawBase .component -}}
{{- if gt (len $candidate) 63 -}}
{{- $baseLength := sub 53 (len .component) | int -}}
{{- printf "%s-%s-%s" ($rawBase | trunc $baseLength | trimSuffix "-") ($candidate | sha256sum | trunc 8) .component -}}
{{- else -}}
{{- $candidate | trimSuffix "-" -}}
{{- end -}}
{{- end -}}

{{- define "twc-lab.labels" -}}
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version | quote }}
app.kubernetes.io/name: {{ include "twc-lab.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end -}}

{{- define "twc-lab.selectorLabels" -}}
app.kubernetes.io/name: {{ include "twc-lab.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end -}}

{{- define "twc-lab.componentSelectorLabels" -}}
{{ include "twc-lab.selectorLabels" .root }}
app.kubernetes.io/component: {{ .component }}
{{- end -}}
