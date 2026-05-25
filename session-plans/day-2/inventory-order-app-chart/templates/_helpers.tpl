{{/*
Chart name, truncated to 63 characters.
*/}}
{{- define "inv-order-app.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Full name: <release>-<chart>, truncated to 63 characters.
*/}}
{{- define "inv-order-app.fullname" -}}
{{- if .Values.fullnameOverride }}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- printf "%s-%s" .Release.Name (include "inv-order-app.name" .) | trunc 63 | trimSuffix "-" }}
{{- end }}
{{- end }}

{{/*
Chart label value: <name>-<version>.
*/}}
{{- define "inv-order-app.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Common labels applied to every resource.
*/}}
{{- define "inv-order-app.labels" -}}
helm.sh/chart: {{ include "inv-order-app.chart" . }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{/*
Selector labels for part-inventory-service.
*/}}
{{- define "inv-order-app.inventory.selectorLabels" -}}
app: part-inventory-service
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{/*
Selector labels for part-order-service.
*/}}
{{- define "inv-order-app.order.selectorLabels" -}}
app: part-order-service
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{/*
Name of the MySQL Secret.
*/}}
{{- define "inv-order-app.mysqlSecretName" -}}
{{- .Values.mysql.secret.name }}
{{- end }}
