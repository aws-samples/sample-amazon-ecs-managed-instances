FROM public.ecr.aws/aws-cli/aws-cli:latest

RUN yum install -y jq wget && yum clean all

COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

ENTRYPOINT ["/entrypoint.sh"]
