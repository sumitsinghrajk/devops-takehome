{{- define "demo-app.fullname" -}}
{{- .Release.Name | trunc 63 | trimSuffix "-" -}}
{{- end }}

{{- define "demo-app.selectorLabels" -}}
app.kubernetes.io/name: {{ .Chart.Name }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{- define "demo-app.labels" -}}
{{ include "demo-app.selectorLabels" . }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
helm.sh/chart: {{ .Chart.Name }}-{{ .Chart.Version }}
{{- end }}
