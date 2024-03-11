package elasticsearchexporter

import (
	"bytes"
	"context"
	"encoding/json"
	"github.com/elastic/go-docappender"
	"go.opentelemetry.io/collector/exporter/exporterhelper"
)

type Request struct {
	bulkIndexer *esBulkIndexerCurrent
	Items       []BulkIndexerItem `json:"Items"`
}

func NewRequest(bulkIndexer *esBulkIndexerCurrent) *Request {
	return &Request{bulkIndexer: bulkIndexer}
}

func (r *Request) Export(ctx context.Context) error {
	for _, item := range r.Items {
		doc := docappender.BulkIndexerItem{
			Index: item.Index,
			Body:  bytes.NewReader(item.Body),
		}
		if err := r.bulkIndexer.Add(doc); err != nil {
			return err // FIXME: merge errors
		}
	}
	_, err := r.bulkIndexer.Flush(ctx)
	return err
}

func (r *Request) ItemsCount() int {
	return len(r.Items)
}

func (r *Request) Add(index string, body []byte) {
	r.Items = append(r.Items, BulkIndexerItem{Index: index, Body: body})
}

type BulkIndexerItem struct {
	Index string
	Body  []byte
}

func MarshalRequest(req exporterhelper.Request) ([]byte, error) {
	b, err := json.Marshal(*req.(*Request))
	return b, err
}

func UnmarshalRequest(b []byte) (exporterhelper.Request, error) {
	var req Request
	err := json.Unmarshal(b, &req)
	return &req, err
}
