{{- define "lynx.env" -}}
{{- range $key, $value := .Values.env }}
- name: {{ $key }}
  value: {{ $value | quote }}
{{- end }}
- name: APP_SECRET
  valueFrom:
    secretKeyRef:
      name: {{ .Values.appSecret.existingSecret }}
      key: {{ .Values.appSecret.key }}
- name: DB_USERNAME
  valueFrom:
    secretKeyRef:
      name: {{ .Values.database.existingSecret }}
      key: {{ .Values.database.keys.username }}
- name: DB_PASSWORD
  valueFrom:
    secretKeyRef:
      name: {{ .Values.database.existingSecret }}
      key: {{ .Values.database.keys.password }}
- name: DB_HOSTNAME
  valueFrom:
    secretKeyRef:
      name: {{ .Values.database.existingSecret }}
      key: {{ .Values.database.keys.hostname }}
- name: DB_DATABASE
  valueFrom:
    secretKeyRef:
      name: {{ .Values.database.existingSecret }}
      key: {{ .Values.database.keys.database }}
- name: DB_PORT
  valueFrom:
    secretKeyRef:
      name: {{ .Values.database.existingSecret }}
      key: {{ .Values.database.keys.port }}
- name: DB_SSL
  valueFrom:
    secretKeyRef:
      name: {{ .Values.database.existingSecret }}
      key: {{ .Values.database.keys.ssl }}
{{- end -}}
