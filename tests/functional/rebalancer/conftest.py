import pytest


@pytest.fixture
def treasury(accounts):
    return accounts[-2]


@pytest.fixture
def portfolio(project, token, treasury, sudo):
    return sudo.deploy(project.Rebalancer, token, treasury)
