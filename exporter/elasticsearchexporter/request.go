package elasticsearchexporter

import (
	"bytes"
	"context"
	"github.com/elastic/go-docappender"
	"sync"
)

type Request struct {
	bulkIndexer *esBulkIndexerCurrent
	mu          *sync.Mutex // FIXME: this is a hack to enable batching. TODO: implement pooling
	Items       []BulkIndexerItem
}

func NewRequest(bulkIndexer *esBulkIndexerCurrent, mu *sync.Mutex) *Request {
	return &Request{bulkIndexer: bulkIndexer, mu: mu}
}

func (r *Request) Export(ctx context.Context) error {
	r.mu.Lock()
	defer r.mu.Unlock()
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
