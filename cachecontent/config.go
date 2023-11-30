package cachecontent

import (
	"time"
)

type Config struct {
	// database
	DBHost                   string
	DBName                   string
	DBPort                   int
	DBSslMode                string
	DBSslRootCert            string
	DBAdminUser              string
	DBAdminPassword          string
	DBUser                   string
	DBPassword               string
	DBDebug                  bool
	DBStatementTimeoutMs     int
	DBMaxConnections         int
	DBMaxIdleConnections     int
	DBMaxConnectionLifetimeS int
	DBReadReplicaHost        string
	DBReadReplicaPort        int
	DBReadReplicaEnabled     bool
	DBWorkMem                int

	// API
	PublicPort         int
	PrivatePort        int
	MetricsPort        int
	MetricsPath        string
	ResponseTimeout    time.Duration
	MaxRequestBodySize int64
	MaxHeaderCount     int
	MaxGinConnections  int
	Ratelimit          int

	// kafka
	KafkaServers           []string
	KafkaAddress           string
	KafkaSslEnabled        bool
	KafkaSslCert           string
	KafkaSslSkipVerify     bool
	KafkaSaslType          *string
	KafkaUsername          string
	KafkaPassword          string
	KafkaGroup             string
	KafkaReaderMinBytes    int
	KafkaReaderMaxBytes    int
	KafkaReaderMaxAttempts int
	KafkaWriterMaxAttempts int
	EventsTopic            string
	EvalTopic              string
	PayloadTrackerTopic    string
	RemediationUpdateTopic string
	NotificationsTopic     string

	// services
	VmaasAddress                  string
	RbacAddress                   string
	ManagerPrivateAddress         string
	ListenerPrivateAddress        string
	EvaluatorUploadPrivateAddress string
	EvaluatorRecalcPrivateAddress string

	// cloudwatch
	CloudWatchAccessKeyID     string
	CloudWatchSecretAccesskey string
	CloudWatchRegion          string
	CloudWatchLogGroup        string

	// prometheus pushgateway
	PrometheusPushGateway string

	// profiler
	ProfilerEnabled bool
}
